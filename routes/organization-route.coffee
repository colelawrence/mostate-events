express = require('express')
router = express.Router()
async = require 'async'
eventManager = require '../lib/database/event-manager'
{ User, Calendar, Event } = require '../lib/database/database-mongoose'
googleHook = require('../lib/database/google-calendar')

# Organization types
types = {
  "C": "Campus Organization",
  "I": "Interest Group",
  "F": "Fraternity",
  "S": "Sorority",
  "R": "Religion",
  "A": "Academic",
  "P": "Sport",
  "O": "Other"
}

router.get '/', (req, res) ->
  res.redirect('/')


router.get '/refresh', (req, res) ->
  email = req.session.email
  if email?
    # Get token for email
    User.getUser email, (error, user) ->
      if error?
        res.redirect '/?error=' + error.message
      else
        # Get auth for querying events
        auth = googleHook.getAuth user.tokens.access_token
        
        async.each(
          user.calendars
          , (calendarId, nextCalendar) ->
            eventManager.indexEvents auth, calendarId, (error, total) ->
              if error?
                console.error error
                nextCalendar error

              else
                res.write """
                Updated calendar: #{calendarId}
                  #{total.updated} events modified
                  #{total.removed} events removed
                  #{total.cancelled} events cancelled
                  #{total.created} events created\n
                """
                nextCalendar()

          , (error) ->
            if error?
              res.end("Error: #{error.message}\n\n#{error.stack}")
            else
              res.end("Updated Events")
        )
  else
    res.redirect '/'

# Normal organization settings page
router.get '/settings', (req, res) ->
  email = req.session.email
  if email?
    # Get token for email
    User.getUser email, (error, user) ->
      if error?
        res.redirect '/?error=' + error.message
      else
        # Get auth for querying calendars
        auth = googleHook.getAuth user.tokens.access_token
        
        # Get calendar list
        listOptions = {
          auth,
          minAccessRole: "reader",
          fields: "items(accessRole,backgroundColor,description,foregroundColor,id,location,summary,timeZone)"
        }
        googleHook.getCalendar().calendarList.list listOptions, (error, calendarList) ->
          if error?
            res.redirect '/?error=' + error.message
          else
            Calendar.find({ owner: user.email })
            .exec (error, mcalendars)->
              if error?
                res.redirect '/?error=' + error.message
              else
                calendarIds = {}
                for c in mcalendars
                  calendarIds[c.calendarId] = c
                for item in calendarList.items
                  c = calendarIds[item.id]
                  item.checked = c?
                  if c?
                    item.suspended = c.suspended
                    item.mdescription = c.description
                    item.mname = c.name
                    item.mtype = c.type

                render = (acted) ->
                  calendars = calendarList.items.sort (a, b) ->
                    if a.checked isnt b.checked
                      return if a.checked then -1 else 1
                    else if a.suspended isnt b.suspended
                      return if a.suspended then 1 else -1
                    else
                      return if a.summary.localeCompare(b.summary)
                  locals = {
                    title: "Organization Settings",
                    types,
                    acted,
                    calendars
                  }

                  res.render "organization-settings-page", locals
                console.log calendarIds
                if req.query.a and calendarIds[req.query.cId]?
                  render { a:req.query.a, targetCalendar: calendarIds[req.query.cId].name }
                else
                  render()
  else
    res.redirect '/'

router.post '/settings/:calendarId', (req, res) ->
  email = req.session.email
  calendarId = decodeURIComponent(req.params.calendarId)
  if email?
    # Get token for email
    User.getUser email, (error, user) ->
      if error?
        res.redirect '/?error=' + error.message
      else if !(~user.calendars.indexOf(calendarId))
        res.redirect '/?error=' + encodeURIComponent("Insufficient permmissions")
      else
        saveCalendar = (error, calendar) ->
          if error?
            res.redirect '/?error=' + error.message
          else
            calendar.name = req.body.name
            calendar.description = req.body.description
            calendar.slug = req.body.name.toLowerCase().replace(/[^a-z0-9]+/g, '-')
            calendar.type = if types[req.body.type]? then req.body.type else "O"
            calendar.color = req.body.color

            calendar.save (error) ->
              urlPath = '/organization/settings/' + encodeURIComponent(calendarId)
              res.redirect urlPath + (if error then '?error=' + error.message else '?saved')
        
        Calendar.getCalendar calendarId, (error, calendar) ->
          if error?
            saveCalendar error
          
          else if calendar?
            # Calendar exists
            saveCalendar null, calendar

          else
            calendar = new Calendar({ calendarId, owner: email })
            saveCalendar null, calendar
  else
    res.redirect '/auth/login'

# Normal organization settings page
router.get '/settings/:calendarId', (req, res) ->
  email = req.session.email
  calendarId = decodeURIComponent(req.params.calendarId)
  if email?
    # Get token for email
    User.getUser email, (error, user) ->
      if error?
        res.redirect '/?error=' + error.message
      else if !(~user.calendars.indexOf(calendarId))
        res.redirect '/?error=' + encodeURIComponent("Insufficient permmissions")
      else
        renderCalendarSettings = (error, calendar, isNew) ->
          if error?
            res.redirect '/?error=' + error.message
          else
            locals = {
              title: "Calendar Settings",
              types,
              isNew,
              calendarName: calendar.name,
              calendarSlug: calendar.slug,
              selectedType: calendar.type,
              calendarColor: calendar.color,
              calendarDescription: calendar.description
            }

            res.render "organization-settings-calendar-page", locals
        Calendar.getCalendar calendarId, (error, calendar) ->
          if error?
            renderCalendarSettings error
          else
            if calendar?
              isNew = false
              renderCalendarSettings null, calendar, isNew

            else
              isNew = true

              # Get auth for querying calendars
              auth = googleHook.getAuth user.tokens.access_token
              
              getOptions = {
                auth,
                calendarId,
                fields: "backgroundColor,description,summary"
              }

              googleHook.getCalendar().calendarList.get getOptions, (error, gcalendar) ->
                if error?
                  renderCalendarSettings error
                else
                  console.log gcalendar
                  
                  calendar = {
                    owner: email,
                    name: gcalendar.summary,
                    slug: gcalendar.summary.toLowerCase().replace(/[^a-z0-9]+/g, "-"),
                    type: "O",
                    description: gcalendar.description,
                    color: gcalendar.backgroundColor
                  }
                  renderCalendarSettings null, calendar, isNew


  else
    res.redirect '/'

module.exports = router
# Description:
#   enable communication with Phabricator via Conduit api
#   listens to conversations and supplement with phabricator metadata
#   when an object is cited.
#
# Dependencies:
#
# Configuration:
#   PHABRICATOR_URL
#   PHABRICATOR_API_KEY
#   PHABRICATOR_PROJECTS
#   PHABRICATOR_BOT_PHID
#
# Commands:
#   anything Txxx - complements with the title of the cited object
#
# Author:
#   mose

Phabricator = require '../lib/phabricator'
moment = require 'moment'
path = require 'path'

phabColumns = { }
if process.env.PHABRICATOR_PROJECTS isnt undefined
  for list in process.env.PHABRICATOR_PROJECTS.split(',')
    [code, label] = list.split ':'
    phabColumns[label] = code

humanFileSize = (size) ->
  i = Math.floor( Math.log(size) / Math.log(1024) )
  return ( size / Math.pow(1024, i) ).toFixed(2) * 1 + ' ' + ['B', 'kB', 'MB', 'GB', 'TB'][i]

module.exports = (robot) ->
  phab = new Phabricator robot, process.env


  robot.respond (/ph(?:ab)? list projects$/), (msg) ->
    msg.send "Known Projects: #{Object.keys(phabColumns).join(', ')}"


  robot.respond /ph(?:ab)? version/, (msg) ->
    pkg = require path.join __dirname, '..', 'package.json'
    msg.send "hubot-phabs module is version #{pkg.version}"
    msg.finish()


  robot.respond (/ph(?:ab)? new ([-_a-zA-Z0-9]+) ([^=]*)(?: = (.*))?$/), (msg) ->
    column = phabColumns[msg.match[1]]
    name = msg.match[2]
    description = msg.match[3]
    if column?
      phab.createTask msg, column, name, description, (body) ->
        if body['error_info']?
          msg.send "#{body['error_info']}"
        else
          id = body['result']['object']['id']
          url = process.env.PHABRICATOR_URL + "/T#{id}"
          phab.recordPhid msg, id
          msg.send "Task T#{id} created = #{url}"
    else
      msg.send 'Command incomplete.'

  robot.respond /ph(?:ab)? paste (.*)$/, (msg) ->
    title = msg.match[1]
    phab.createPaste msg, title, (body) ->
      if body['error_info']?
        msg.send "#{body['error_info']}"
      else
        id = body['result']['object']['id']
        url = process.env.PHABRICATOR_URL + "/paste/edit/#{id}"
        phab.recordPhid msg, id
        msg.send "Paste P#{id} created = edit on #{url}"


  robot.respond (/ph(?:ab)? count ([-_a-zA-Z0-9]+)/), (msg) ->
    column = phabColumns[msg.match[1]]
    if column?
      phab.listTasks msg, column, (body) ->
        if Object.keys(body['result']).length is 0
          msg.send "#{msg.match[1]} has no tasks."
        else
          msg.send "#{msg.match[1]} has #{Object.keys(body['result']).length} tasks."
    else
      msg.send 'Command incomplete.'


  robot.respond /ph(?:ab)?(?: T([0-9]+) ?)?$/, (msg) ->
    id = msg.match[1] ? phab.retrievePhid(msg)
    unless id?
      msg.send "Sorry, you don't have any task active right now."
      msg.finish()
      return
    phab.taskInfo msg, id, (body) ->
      if body['error_info']?
        msg.send "oops T#{id} #{body['error_info']}"
      else
        phab.withUserByPhid robot, body.result.ownerPHID, (owner) ->
          status = body.result.status
          priority = body.result.priority
          phab.recordPhid msg, id
          msg.send "T#{id} has status #{status}, " +
                   "priority #{priority}, owner #{owner.name}"
    msg.finish()


  robot.respond new RegExp(
    "ph(?:ab)?(?: T([0-9]+))? (?:is )?(#{Object.keys(phab.statuses).join('|')})$"
  ), (msg) ->
    id = msg.match[1] ? phab.retrievePhid(msg)
    unless id?
      msg.send "Sorry, you don't have any task active right now."
      msg.finish()
      return
    status = msg.match[2]
    phab.updateStatus msg, id, status, (body) ->
      if body['error_info']?
        msg.send "oops T#{id} #{body['error_info']}"
      else
        msg.send "Ok, T#{id} now has status #{body['result']['statusName']}."
    msg.finish()


  robot.respond new RegExp(
    "ph(?:ab)?(?: T([0-9]+))? (?:is )?(#{Object.keys(phab.priorities).join('|')})$"
  ), (msg) ->
    id = msg.match[1] ? phab.retrievePhid(msg)
    unless id?
      msg.send "Sorry, you don't have any task active right now."
      msg.finish()
      return
    priority = msg.match[2]
    phab.updatePriority msg, id, priority, (body) ->
      if body['error_info']?
        msg.send "oops T#{id} #{body['error_info']}"
      else
        msg.send "Ok, T#{id} now has priority #{body['result']['priority']}"
    msg.finish()


  robot.respond /ph(?:ab)? ([^ ]*)$/, (msg) ->
    name = msg.match[1]
    assignee = robot.brain.userForName(name)
    unless assignee
      msg.send "Sorry, I have no idea who #{name} is. Did you mistype it?"
      return
    phab.withUser msg, assignee, (userPhid) ->
      msg.send "Hey I know #{name}, he's #{userPhid}"


  robot.respond /ph(?:ab)? me as (.*@.*)$/, (msg) ->
    email = msg.match[1]
    msg.message.user.email_address = email
    robot.brain.save()
    msg.send "Okay, I'll remember your email is #{email}"


  robot.respond /ph(?:ab)? ([^ ]*) *?= *?([^ ]*@.*)$/, (msg) ->
    who = msg.match[1]
    email = msg.match[2]
    assignee = robot.brain.userForName(who)
    unless assignee
      msg.send "Sorry I have no idea who #{who} is. Did you mistype it?"
      return
    assignee.email_address = email
    msg.send "Okay, I'll remember #{who} email as #{email}"

  robot.respond new RegExp(
    'ph(?:ab)?(?: assign)? (?:([^ ]+)(?: (?:to|on) (T)([0-9]+))?|(?:T([0-9]+) )?(?:to|on) ([^ ]+))$'
  ), (msg) ->
    if msg.match[2] is 'T'
      who = msg.match[1]
      what = msg.match[3]
    else
      who = msg.match[5]
      what = msg.match[4]
    id = what ? phab.retrievePhid(msg)
    unless id?
      msg.send "Sorry, you don't have any task active right now."
      msg.finish()
      return
    assignee = robot.brain.userForName(who)
    if assignee?
      phab.withUser msg, assignee, (userPhid) ->
        phab.assignTask msg, id, userPhid, (body) ->
          if body['error_info']?
            msg.send "#{body['error_info']}"
          else
            msg.send "Ok. T#{id} is now assigned to #{assignee.name}"
    else
      msg.send "Sorry I don't know who is #{who}, can you .phab #{who} = <email>"
    msg.finish()


  robot.hear new RegExp(
    "(?:.+|^)(?:(#{process.env.PHABRICATOR_URL})/?| |^)" +
    '(?:(T|F|P|M|B|Q|L|V)([0-9]+)|(r[A-Z]+[a-f0-9]{10,}))'
  ), (msg) ->
    url = msg.match[1]
    type = msg.match[2] ? msg.match[4]
    id = msg.match[3]
    switch
      when 'T' is type
        phab.taskInfo msg, id, (body) ->
          if body['error_info']?
            msg.send "oops #{type}#{id} #{body['error_info']}"
          else
            closed = ''
            if body['result']['isClosed'] is true
              closed = " (#{body['result']['status']})"
            if url?
              msg.send "#{type}#{id}#{closed} - #{body['result']['title']} " +
                       "(#{body['result']['priority']})"
            else
              msg.send "#{body['result']['uri']}#{closed} - #{body['result']['title']} " +
                       "(#{body['result']['priority']})"
            phab.recordPhid msg, id
      when 'F' is type
        phab.fileInfo msg, id, (body) ->
          if body['error_info']?
            msg.send "oops #{type}#{id} #{body['error_info']}"
          else
            size = humanFileSize(body['result']['byteSize'])
            if url?
              msg.send "#{type}#{id} - #{body['result']['name']} " +
                       "(#{body['result']['mimeType']} #{size})"
            else
              msg.send "#{body['result']['uri']} - #{body['result']['name']} "+
                       "(#{body['result']['mimeType']} #{size})"
      when 'P' is type
        phab.pasteInfo msg, id, (body) ->
          if Object.keys(body['result']).length < 1
            msg.send "oops #{type}#{id} was not found."
          else
            lang = ''
            key = Object.keys(body['result'])[0]
            if body['result'][key]['language'] isnt ''
              lang = " (#{body['result'][key]['language']})"
            if url?
              msg.send "#{type}#{id} - #{body['result'][key]['title']}#{lang}"
            else
              msg.send "#{body['result'][key]['uri']} - #{body['result'][key]['title']}#{lang}"
      when /^M|B|Q|L|V$/.test type
        phab.genericInfo msg, "#{type}#{id}", (body) ->
          if Object.keys(body['result']).length < 1
            msg.send "oops #{type}#{id} was not found."
          else
            v = body['result']["#{type}#{id}"]
            status = ''
            if v['status'] is 'closed'
              status = " (#{v['status']})"
            if url?
              msg.send "#{v['fullName']}#{status}"
              return
            else
              fullname = v['fullName'].replace("#{type}#{id}: ", '').replace("#{type}#{id} ", '')
              msg.send "#{v['uri']} - #{fullname}#{status}"
              return
      when /^r[A-Z]+[a-f0-9]{10,}$/.test type
        phab.genericInfo msg, type, (body) ->
          if Object.keys(body['result']).length < 1
            msg.send "oops #{type} was not found."
          else
            v = body['result']["#{type}"]
            status = ''
            if v['status'] is 'closed'
              status = " (#{v['status']})"
            if url?
              msg.send "#{v['fullName']}#{status}"
              return
            else
              fullname = v['fullName'].replace "#{type}: ", ''
              msg.send "#{v['uri']} - #{fullname}#{status}"
              return
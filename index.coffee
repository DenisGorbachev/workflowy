_ = require 'lodash'
Q = require 'q'
debug = require('debug')('workflowy')
request = require 'reqrap'
utils = require './lib/utils'
util = require 'util'

request.use require('reqrap/debug'), name: 'workflowy-request'
request.use require('reqrap/throttle'), millis: 1000

makeUrls = (workflowy) ->
  {
    login: 'https://workflowy.com/accounts/login/'
    meta: "https://workflowy.com/get_initialization_data?client_version=#{Workflowy.clientVersion}#{if workflowy.shareId then "&share_id=#{workflowy.shareId}" else ""}"
    update: 'https://workflowy.com/push_and_poll'
  }

module.exports = class Workflowy
  @clientVersion: 18

  constructor: (@username, @password, {jar, shareId} = {}) ->
    @jar = if jar then request.jar(jar) else request.jar()
    @request = request.defaults {@jar, json: true}
    @_lastTransactionId = null
    @shareId = utils.parseShareId(shareId)
    @urls = makeUrls(this)
    @stopping = false
    @plugins = {}

  use: (module, options={}) -> module this, options; this

  start: ->
    plugin?.start?() for name, plugin of @plugins
    return

  stop: ->
    @stopping ||= Q.all(plugin?.stop?() for name, plugin of @plugins)

  ###
  # takes a shareId or a share URL, such as <https://workflowy.com/s/BtARFRlTVt>
  ###
  quarantine: (shareId) ->
    newInstance = Object.create this
    newInstance.shareId = utils.parseShareId(shareId)
    newInstance.urls = makeUrls(newInstance)
    delete newInstance.meta
    newInstance

  asText: (roots) ->
    @meta || @refresh()
    @nodes.then (allNodes) ->
      roots ?= allNodes.filter (node) -> node.parentId is 'None'
      roots = [roots] unless _.isArray roots
      utils.treeToOutline(roots)

  login: ->
    if @shareId
      Q.when()
    else
      Q.ninvoke @request,
        'post'
        url: @urls.login
        form: {@username, @password}
      .then ([resp, body]) ->
        unless (resp.statusCode is 302) and (resp.headers.location is "https://workflowy.com/")
          utils.checkForErrors arguments...
        return
      .fail (err) ->
        console.error "Error logging in: ", err
        throw err

  refresh: ->
    meta = =>
      Q.ninvoke @request,
        'get'
        url: @urls.meta
      .then ([resp,body]) ->
        utils.checkForErrors arguments...
        body

    @meta = meta().fail (err) =>
      @login().then meta
      .fail (err) ->
        console.error "Error fetching document root:", err
        throw err

    @roots = @meta.then (body) =>
      meta = body.projectTreeData.mainProjectTreeInfo
      @_lastTransactionId = meta.initialMostRecentOperationTransactionId
      meta.rootProjectChildren

    @nodes = @roots.then (roots) =>
      utils.flattenTree roots

  _update: (operations) ->
    @meta.then (meta) =>
      timestamp = utils.getTimestamp meta
      {clientId} = meta.projectTreeData

      operation.client_timestamp ?= timestamp for operation in operations

      Q.ninvoke @request,
        'post'
        url: @urls.update
        form:
          client_id: clientId
          share_id: @shareId
          client_version: Workflowy.clientVersion
          push_poll_id: utils.makePollId()
          push_poll_data: JSON.stringify [
            share_id: @shareId
            most_recent_operation_transaction_id: @_lastTransactionId
            operations: operations
          ]
      .then ([resp, body]) =>
        utils.checkForErrors arguments...
        @_lastTransactionId = body.results[0].new_most_recent_operation_transaction_id
        [resp, body, timestamp]


  ###
  # @search [optional]
  # @returns an array of nodes that match the given string, regex or function
  ###
  find: (search, completed) ->
    @meta || @refresh()

    unless !!search
      condition = if completed? then (-> true) else null
    else if _.isString search
      condition = (node) -> node.nm.indexOf(search) isnt -1
    else if _.isRegExp search
      condition = (node) -> search.test node.nm
    else if _.isFunction search
      condition = search
    else
      (deferred = Q.defer()).reject new Error 'unknown search type'
      return deferred

    if completed?
      originalCondition = condition
      condition = (node) ->
        (node.cp? is !!completed) and originalCondition node

    @nodes.then (nodes) ->
      nodes = _.filter nodes, condition if condition
      nodes

  ###
  # nodes is an array with {name, description}
  # startIndex is the insertion position
  ###
  addChildren: (nodes, parentNode={id: 'None'}, startIndex=0) ->
    @meta || @refresh()
    nodes = [nodes] unless _.isArray nodes
    return Q() unless nodes.length > 0
    parentId = parentNode.id

    operations = []
    i = nodes.length
    while --i >= 0
      node = nodes[i]
      node.id ||= utils.makeNodeId()
      operations.push
        type: 'create'
        undo_data: {}
        data:
          parentid: parentId
          projectid: node.id
          priority: startIndex[i] ? startIndex
      operations.push
        type: 'edit'
        data:
          projectid: node.id
          name: node.name || ''
          description: node.description || ''
        undo_data:
          previous_last_modified: 0
          previous_name: ''

    @_update operations
    .then ([resp,body,timestamp]) =>
      @refresh()
      return

  delete: (nodes) ->
    debug "deleting nodes #{util.inspect nodes}"

    @meta || @refresh()
    nodes = [nodes] unless _.isArray nodes
    return Q() unless nodes.length > 0

    operations = for node in nodes
      type: 'delete'
      data: projectid: node.id
      undo_data:
        previous_last_modified: node.lm
        parentid: node.parentId
        priority: 5

    @_update operations
    .then =>
      # just fetch the nodes again
      @refresh()
      return

  ###
  # makes the given nodes bold or not bold
  ###
  bold: (nodes, tf=true) ->
    @meta || @refresh()
    nodes = [nodes] unless _.isArray nodes
    nodes = nodes.filter (node) -> /^<b>/.test(node.nm||'') isnt tf
    return Q() unless nodes.length > 0

    operations = for node in nodes
      type: 'edit'
      data:
        name: utils.makeBold(node.nm,tf)
        projectid: node.id
      undo_data:
        previous_last_modified: node.lm
        previous_completed: if tf then false else node.cp

    @_update operations
    .then ([resp,body,timestamp]) =>
      # now update the nodes
      for node, i in nodes
        node.nm = operations[i].data.name
        node.lm = timestamp

  complete: (nodes, tf=true) ->
    @meta || @refresh()
    nodes = [nodes] unless _.isArray nodes
    nodes = nodes.filter (node) -> node.cp? isnt tf
    return Q() unless nodes.length > 0

    operations = for node in nodes
      type: if tf then 'complete' else 'uncomplete'
      data: projectid: node.id
      undo_data:
        previous_last_modified: node.lm
        previous_completed: if tf then false else node.cp

    @_update operations
    .then ([resp,body,timestamp]) =>
      # now update the nodes
      for node, i in nodes
        if tf
          node.cp = timestamp
        else
          delete node.cp
        node.lm = timestamp

      return

  ##
  # newNames is either an array of names corresponding to each node or an
  # object mapping node id to name. both args can also be strings to apply to
  # one node.
  #
  # newNotes is similarly structured
  #
  # @returns the new lm value for the updated nodes
  ##
  update: (nodes, newNames={}, newNotes={}) ->
    @meta || @refresh()

    unless _.isArray nodes
      nodes = [nodes]
      newNames = [newNames] if _.isString(newNames)

    return Q(0) unless nodes.length > 0

    operations = for node, i in nodes
      type: 'edit',
      data:
        projectid: node.id
        name: newNames[i] ? newNames[node.id]
        description: newNotes[i] ? newNotes[node.id]
      undo_data:
        previous_last_modified: node.lm
        previous_name: node.nm

    @_update operations
    .then ([resp,body,timestamp]) =>
      for node, i in nodes
        node.nm = newNames[i] ? newNames[node.id]
        node.no = newNotes[i] ? newNotes[node.id] ? node.no
        node.lm = timestamp
      timestamp

  timestampToDate: (cpTime) ->
    @meta.then (meta) -> utils.timestampToDate cpTime


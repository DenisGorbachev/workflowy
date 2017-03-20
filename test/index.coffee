assert = require 'assert'
fs = require 'fs'
Q = require 'q'
path = require 'path'
Workflowy = require '../'
FileCookieStore = require 'tough-cookie-filestore-mikerobe'
proxy = require '../lib/proxy'
utils = require '../lib/utils'

username = 'mikerobe@me.com'
password = 'test'
cookiesPath = path.join(__filename, '../cookies.json')

initialList = """
  - foo
    - <b>bold</b> #today
      - and another
      - or another
      - a final entry
  - bar
    - [COMPLETE] baz
    - [COMPLETE] boo
  - [COMPLETE] top complete
    - not complete
  """

fc = null
workflowy = null

workflowyMatchesOutline = (inst, outline) ->
  [outline, inst] = [inst, workflowy] if arguments.length <2
    
  inst.find().then (nodes) ->
    # find the root nodes in the flat list
    nodes = nodes.filter (node) -> node.parentId is 'None'
    assert.equal(utils.treeToOutline(nodes),outline)

addChildrenTest = (workflowy) ->
  workflowy.addChildren [{name: 'first'}, {name: 'second'}]
  .then ->
    workflowy.find().then (nodes) ->
      assert.equal(nodes[0].nm, 'first')
      assert.equal(nodes[1].nm, 'second')

      workflowy.addChildren [{name: 'underFirst1'}, {name: 'underFirst2'}], nodes[0]
      .then ->
        workflowy.find().then (nodes) ->
          assert.equal(nodes[0].nm, 'first')
          assert.equal(nodes[1].nm, 'underFirst1')
          assert.equal(nodes[2].nm, 'underFirst2')
          assert.equal(nodes[3].nm, 'second')

          assert.equal(nodes[1].parentId, nodes[0].id)
          assert.equal(nodes[2].parentId, nodes[0].id)

          workflowy.addChildren [{name: 'between underFirst1 and underFirst2 a'}, {name: 'between underFirst1 and underFirst2 b'}], nodes[0], 1
          .then ->
            workflowy.find().then (nodes) ->
              assert.equal(nodes[0].nm, 'first')
              assert.equal(nodes[1].nm, 'underFirst1')
              assert.equal(nodes[2].nm, 'between underFirst1 and underFirst2 a')
              assert.equal(nodes[3].nm, 'between underFirst1 and underFirst2 b')
              assert.equal(nodes[4].nm, 'underFirst2')
              assert.equal(nodes[5].nm, 'second')

              assert.equal(nodes[0].parentId, 'None')
              assert.equal(nodes[1].parentId, nodes[0].id)
              assert.equal(nodes[2].parentId, nodes[0].id)
              assert.equal(nodes[3].parentId, nodes[0].id)
              assert.equal(nodes[4].parentId, nodes[0].id)
              assert.equal(nodes[5].parentId, 'None')

  .then ->
    root = "foo #{Date.now()}"
    rootNode = null
    workflowy.addChildren name: root
    .then -> workflowy.find()
    .then (nodes) ->
      rootNode = nodes[0]
      assert.equal(nodes[0].nm,root)
      workflowy.addChildren [{name: '1'},{name: '3'},{name:'5'}], nodes[0]
    .then -> workflowy.find( (node) -> node.id is rootNode.id )
    .then (nodes) -> rootNode = nodes[0]
    .then -> workflowy.asText(rootNode)
    .then (text) ->
      assert.equal text, """
      - #{root}
        - 1
        - 3
        - 5
      """
      workflowy.addChildren [{name: '2'},{name: '4'}], rootNode, [1,2]
    .then -> workflowy.find( (node) -> node.id is rootNode.id )
    .then (nodes) -> rootNode = nodes[0]
    .then -> workflowy.asText(rootNode)
    .then (text) ->
      assert.equal text, """
      - #{root}
        - 1
        - 2
        - 3
        - 4
        - 5
      """

  # add at the botom of the doc with a high priority
  .then ->
    names = [1..10].map (num) -> ''+num
    workflowy.addChildren names.map (name) -> {name}
    .then -> workflowy.find()
    .then (nodes) ->
      # first 10 nodes should have the given names
      for name,i in names
        assert.equal(nodes[i].nm, names[i])

      # now add a node with a crazy priority
      workflowy.addChildren({name: 'at the bottom'},null, 1e6)
    .then -> workflowy.find()
    .then (nodes) ->
      # first 10 nodes should still have the given names
      for name,i in names
        assert.equal(nodes[i].nm, names[i])

      # last node is known
      assert.equal(nodes[nodes.length-1].nm, 'at the bottom')


shareIdTests = (useQuarantine) ->
  rootName = "Book list"
  throw new Error "env var WORKFLOWY_SHAREID is required to test quarantine and share id" unless shareId = process.env.WORKFLOWY_SHAREID
  fcSub = new FileCookieStore('cookies.json')
  workflowySub = null

  beforeEach ->
    # clean up all the nodes under the book list
    workflowy = new Workflowy username, password, jar: fc
    if useQuarantine
      workflowySub = workflowy.quarantine shareId
    workflowy.find(rootName)
    .then (nodes) ->
      assert.equal nodes.length, 1
      if (children = nodes[0].ch)?.length
        workflowy.delete(children)
        .then ->
          unless useQuarantine
            workflowySub = new Workflowy username, password, jar: fcSub, shareId: shareId
      else
        unless useQuarantine
          workflowySub = new Workflowy username, password, jar: fcSub, shareId: shareId

  describe '#find', ->
    it 'should return only nodes under the given Id', ->
      workflowySub.refresh()
      workflowyMatchesOutline workflowySub, ""

  describe '#addChildren shareId', ->
    it 'should add children under the expected root node', ->
      newRootNode = "top level child #{Date.now()}"
      newShareNode = "share #{Date.now()}"

      Q.all([
        workflowy.addChildren name: newRootNode
        workflowySub.addChildren name: newShareNode
      ]).then ->
        workflowyMatchesOutline workflowySub, "- #{newShareNode}"
      .then ->
        workflowy.find().then (nodes) ->
          assert.equal nodes[0].nm, newRootNode



describe.skip 'Workflowy over the wire', ->
  username = process.env.WORKFLOWY_USERNAME
  password = process.env.WORKFLOWY_PASSWORD

  beforeEach ->
    (console.error "Workflowy username and password must be provided through environmental variables."; process.exit 1) unless username and password

    Q.ninvoke fs, 'unlink', cookiesPath
    .then Q, Q
    .then ->
      fc = new FileCookieStore('cookies.json')

  describe.skip '#constructor', ->
    it 'with empty cookies, should make 3 initial requests (meta, login, meta) then 1 with cookies present', ->
      workflowy = new Workflowy username, password, jar: fc
      workflowy.refresh()
      workflowy.nodes.then ->
        assert.equal(workflowy._requests,3)
        workflowy = new Workflowy username, password, jar: fc
        workflowy.nodes.then ->
          assert.equal(workflowy._requests, 1)

  describe.skip '#update', ->
    it 'should reflect an empty tree after deleting all top level nodes', ->
      workflowy = new Workflowy username, password, jar: fc
      workflowy.refresh()
      workflowy.nodes.then ->
        workflowy.find().then (nodes) ->
          workflowy.delete(nodes).then ->
            workflowy.nodes.then (nodes) ->
              assert.equal(nodes.length, 0)
              assert(workflowy._requests, 7)

  describe '#addChildren', ->
    it 'should add child nodes where expected in the tree', ->
      this.timeout(60000)
      workflowy = new Workflowy username, password, jar: fc
      workflowy.refresh()
      addChildrenTest workflowy

  # describe.skip 'with a shareId in constructor', ->
  #   shareIdTests false

  # describe.skip '#quarantine', ->
  #   shareIdTests true

describe 'Workflowy with proxy', ->
  beforeEach ->
    workflowy = proxy new Workflowy username, password
    workflowy.request.populate initialList

  describe '#find', ->
    it 'should reflect an initialized tree with empty search', ->
      workflowy.find().then (nodes) -> assert.equal(nodes.length, 10)

    it 'should find nodes that match a string', ->
      workflowy.find('another').then (nodes) ->
        assert.equal(nodes.length, 2)
        assert.equal(nodes[0].nm, 'and another')
        assert.equal(nodes[1].nm, 'or another')

    it 'should find nodes that are complete', ->
      workflowy.find(null, true).then (nodes) ->
        assert.equal(nodes.length, 3)
        assert.equal(nodes[0].nm, 'baz')
        assert.equal(nodes[1].nm, 'boo')
        assert.equal(nodes[2].nm, 'top complete')

    it 'should find nodes that are not complete', ->
      workflowy.find(null, false).then (nodes) ->
        assert.equal(nodes.length, 7)
        assert.equal(nodes[0].nm, 'foo')
        assert.equal(nodes[1].nm, '<b>bold</b> #today')
        assert.equal(nodes[2].nm, 'and another')
        assert.equal(nodes[3].nm, 'or another')
        assert.equal(nodes[4].nm, 'a final entry')
        assert.equal(nodes[5].nm, 'bar')
        assert.equal(nodes[6].nm, 'not complete')

  describe '#update', ->
    it 'should allow passing an object mapping node id to new name', ->
      id = null
      workflowy.find('and another').then (nodes) ->
        id = nodes[0].id
        map = {}; map[id] = "a new name"
        workflowy.update(nodes[0], map).then -> workflowyMatchesOutline """
          - foo
            - <b>bold</b> #today
              - a new name
              - or another
              - a final entry
          - bar
            - [COMPLETE] baz
            - [COMPLETE] boo
          - [COMPLETE] top complete
            - not complete
          """

  describe '#complete', ->
    it 'should mark as complete the passed nodes', ->
      workflowy.find('another').then (nodes) ->
        workflowy.complete(nodes).then -> workflowyMatchesOutline """
          - foo
            - <b>bold</b> #today
              - [COMPLETE] and another
              - [COMPLETE] or another
              - a final entry
          - bar
            - [COMPLETE] baz
            - [COMPLETE] boo
          - [COMPLETE] top complete
            - not complete
          """

    it 'should mark as not complete the passed nodes', ->
      workflowy.find('top', true).then (nodes) ->
        workflowy.complete(nodes, false).then ->
          workflowyMatchesOutline """
            - foo
              - <b>bold</b> #today
                - and another
                - or another
                - a final entry
            - bar
              - [COMPLETE] baz
              - [COMPLETE] boo
            - top complete
              - not complete
            """

  describe '#bold', ->
    it 'should make nodes not previously bold, bold', ->
      workflowy.find('top').then (nodes) ->
        workflowy.bold(nodes).then -> workflowyMatchesOutline """
          - foo
            - <b>bold</b> #today
              - and another
              - or another
              - a final entry
          - bar
            - [COMPLETE] baz
            - [COMPLETE] boo
          - [COMPLETE] <b>top complete</b>
            - not complete
          """

  describe '#delete', ->
    it 'should only delete the selected nodes, including children', ->
      workflowy.find('#today').then (nodes) ->
        workflowy.delete(nodes)
      .then -> workflowyMatchesOutline """
        - foo
        - bar
          - [COMPLETE] baz
          - [COMPLETE] boo
        - [COMPLETE] top complete
          - not complete
        """

  describe '#asText', ->
    it 'should return the same outline given', ->
      workflowy.asText().then (text) ->
        assert.equal text, initialList
    it 'should make expected modifications', ->
      workflowy.find('',true)
      .then (nodes) -> workflowy.delete(nodes)
      .then -> workflowy.asText()
      .then (text) -> assert.equal text, """
        - foo
          - <b>bold</b> #today
            - and another
            - or another
            - a final entry
        - bar
        """
    it 'should return the same outline when there are notes', ->
      workflowyWithNote = proxy new Workflowy username, password
      workflowyWithNote.request.populate newText = '''
        - parent
          | parent note
          | parent line 2
          - child
            | child note 1
            |    child note 2
            | child 3
            - grandchild 1
            - grandchild 2
        '''
      workflowyWithNote.asText().then (text) ->
        assert.equal text, newText
  describe '#populate', ->
    it 'should handle the description field (notes)', ->
      workflowyWithNote = proxy new Workflowy username, password
      workflowyWithNote.request.populate '''
        - top item
          | here's a note associated with the item
        '''
      workflowyWithNote.find()
        .then (nodes) ->
          assert.equal nodes.length, 1
          node = nodes[0]
          assert.equal !!node.cp, false
          assert.equal node.nm, 'top item'
          assert.equal node.no, '''here's a note associated with the item'''

    it 'should handle multi-line notes and lines with spaces', ->
      workflowyWithNote = proxy new Workflowy username, password
      workflowyWithNote.request.populate '''
        - top item
          | here's a note associated with the item
          | here's a second line on the same note
          |   a third line that's indented
        '''
      workflowyWithNote.find()
        .then (nodes) ->
          assert.equal nodes.length, 1
          node = nodes[0]
          assert.equal !!node.cp, false
          assert.equal node.nm, 'top item'
          assert.equal node.no, '''here's a note associated with the item\nhere's a second line on the same note\n  a third line that's indented'''
    it 'should handle notes on child nodes', ->
      workflowyWithNote = proxy new Workflowy username, password
      workflowyWithNote.request.populate '''
        - parent
          | parent note
          | parent line 2
          - child
            | child note 1
            |    child note 2
            | child 3
            - grandchild 1
            - grandchild 2
        '''
      workflowyWithNote.find()
        .then (nodes) ->
          assert.equal nodes.length, 4
          parent = nodes[0]
          child = nodes[1]
          grandchild1 = nodes[2]
          grandchild2 = nodes[3]

          assert.equal child.parentId, parent.id
          assert.equal grandchild1.parentId, child.id
          assert.equal grandchild2.parentId, child.id

          assert.equal parent.ch.length, 1
          assert.equal parent.ch[0], child
          assert.equal child.ch.length, 2
          assert.equal child.ch[0], grandchild1
          assert.equal child.ch[1], grandchild2

          assert.equal parent.nm, 'parent'
          assert.equal child.nm, 'child'
          assert.equal grandchild1.nm, 'grandchild 1'
          assert.equal grandchild2.nm, 'grandchild 2'

          assert.equal parent.no, 'parent note\nparent line 2'
          assert.equal child.no, 'child note 1\n   child note 2\nchild 3'
          assert.equal !!grandchild1.no, false
          assert.equal !!grandchild2.no, false

  describe '#addChildren', ->
    it 'should add child nodes where expected in the tree', ->
      addChildrenTest workflowy

describe 'Workflowy utils', ->
  describe '#addTag', ->
    it 'should add a tag if it does not exist', ->
      name = 'foo bar'
      assert.equal(utils.addTag(name, 'today'), name + ' #today')
      name = 'foo bar #todays'
      assert.equal(utils.addTag(name, 'today'), name + ' #today')

    it 'should not add a tag if it does exist', ->
      name = '#today foo bar'
      assert.equal(utils.addTag(name, 'today'), name)
      name = 'foo bar #today'
      assert.equal(utils.addTag(name, 'today'), name)

    it 'should insert the tag within bold', ->
      name = '<b>foo bar</b>'
      assert.equal(utils.addTag(name, 'today'), '<b>foo bar #today</b>')

  describe '#removeTag', ->
    it 'should remove a tag if it exists', ->
      name = 'foo #today bar'
      assert.equal(utils.removeTag(name, 'today'), 'foo bar')
    it 'should do nothing if the tag does not exist', ->
      name = 'foo #todays bar'
      assert.equal(utils.removeTag(name, 'today'), name)
    it 'should remove spacing before and after as appropriate', ->
      name = 'foo #today bar'
      assert.equal(utils.removeTag(name, 'today'), 'foo bar')
      name = '#today bar'
      assert.equal(utils.removeTag(name, 'today'), 'bar')
      name = 'bar #today'
      assert.equal(utils.removeTag(name, 'today'), 'bar')
      name = '#today #week this was for this week'
      assert.equal(utils.removeTag(name, 'today'), '#week this was for this week')
    it 'should remove tags with metadata, stopping at the end of the data', ->
      name = '#today #weekly/1/2 this was for this week'
      assert.equal(utils.removeTag(name, 'weekly'), '#today this was for this week')
      name = '#today #thursday/1p. this was for this week'
      assert.equal(utils.removeTag(name, 'thursday'), '#today. this was for this week')
      name = '#today #thursday/1p/2.5h. this was for this week'
      assert.equal(utils.removeTag(name, 'thursday'), '#today. this was for this week')
      name = 'hello world #today #thursday/1p/2.5h'
      assert.equal(utils.removeTag(name, 'thursday'), 'hello world #today')
      name = 'hello world #today #thursday/1p/2.5h.'
      assert.equal(utils.removeTag(name, 'thursday'), 'hello world #today.')


  describe '#addContext', ->
    it 'should add a context if it does not exist', ->
      name = 'foo bar'
      assert.equal(utils.addContext(name, 'home'), name + ' @home')
      name = 'foo bar @homes'
      assert.equal(utils.addContext(name, 'home'), name + ' @home')

    it 'should not add a context if it does exist', ->
      name = '@home foo bar'
      assert.equal(utils.addContext(name, 'home'), name)
      name = 'foo bar @home'
      assert.equal(utils.addContext(name, 'home'), name)

    it 'should insert the context within bold', ->
      name = '<b>foo bar</b>'
      assert.equal(utils.addContext(name, 'home'), '<b>foo bar @home</b>')

  describe '#removeContext', ->
    it 'should remove a context if it exists', ->
      name = 'foo @home bar'
      assert.equal(utils.removeContext(name, 'home'), 'foo bar')
    it 'should do nothing if the context does not exist', ->
      name = 'foo @homes bar'
      assert.equal(utils.removeContext(name, 'home'), name)
    it 'should remove spacing before and after as appropriate', ->
      name = 'foo @home bar'
      assert.equal(utils.removeContext(name, 'home'), 'foo bar')
      name = '@home bar'
      assert.equal(utils.removeContext(name, 'home'), 'bar')
      name = 'bar @home'
      assert.equal(utils.removeContext(name, 'home'), 'bar')
      name = '@home #week this was for this week'
      assert.equal(utils.removeContext(name, 'home'), '#week this was for this week')
    it 'should remove context with metadata', ->
      name = '@home #week this was for this week @rating/1.5'
      assert.equal(utils.removeContext(name, 'rating'), '@home #week this was for this week')
      name = '@home #week this was for this week @rating/1.5 and more'
      assert.equal(utils.removeContext(name, 'rating'), '@home #week this was for this week and more')

  describe '#getContexts', ->
    it 'should return an array of all the contexts', ->
      arr = utils.getContexts "foo @bar @baz hello @world: yay @mundo"
      assert.equal(arr.length, 3)
      assert('bar' in arr)
      assert('baz' in arr)
      assert('mundo' in arr)

  describe '#inheritContexts', ->
    it 'should inherit all the (regular) contexts from ancestors', ->
      workflowy = proxy new Workflowy username, password
      workflowy.request.populate """
        - hello @bar
          - another @baz:
            - and a final hello
        """
      workflowy.find().then (nodes) ->
        assert.equal utils.inheritContexts(nodes[2].nm, nodes[2]), "and a final hello @bar"

  describe '#getBubbledContexts', ->
    it 'should return an array of all the bubbled contexts', ->
      arr = utils.getBubbledContexts "foo @bar @baz hello @world: yay @mundo"
      assert.equal(arr.length, 1)
      assert('world' in arr)

  describe '#bubbleUpContexts', ->
    it 'should bubble not present contexts and remove unnecessary bubbles', ->

      workflowy = proxy new Workflowy username, password
      workflowy.request.populate """
        - hello @bar @bazoo:
          - another @baz:
            - and a final hello @baz @hello
        """
      workflowy.find().then (nodes) ->
        assert.equal utils.bubbleUpContexts(nodes[0].nm, nodes[0]), "hello @bar @baz: @hello:"

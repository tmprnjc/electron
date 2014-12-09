v8Util = process.atomBinding 'v8_util'
guestViewInternal = require './guest-view-internal'
webViewConstants = require './web-view-constants'
webFrame = require 'web-frame'
remote = require 'remote'

# Attributes.
AUTO_SIZE_ATTRIBUTES = [
  webViewConstants.ATTRIBUTE_AUTOSIZE,
  webViewConstants.ATTRIBUTE_MAXHEIGHT,
  webViewConstants.ATTRIBUTE_MAXWIDTH,
  webViewConstants.ATTRIBUTE_MINHEIGHT,
  webViewConstants.ATTRIBUTE_MINWIDTH,
]

# ID generator.
nextId = 0
getNextId = -> ++nextId

# Represents the internal state of the WebView node.
class WebView
  constructor: (@webviewNode) ->
    v8Util.setHiddenValue @webviewNode, 'internal', this
    @attached = false
    @pendingGuestCreation = false
    @elementAttached = false

    @beforeFirstNavigation = true
    @contentWindow = null
    # Used to save some state upon deferred attachment.
    # If <object> bindings is not available, we defer attachment.
    # This state contains whether or not the attachment request was for
    # newwindow.
    @deferredAttachState = null

    # on* Event handlers.
    @on = {}

    @browserPluginNode = @createBrowserPluginNode()
    shadowRoot = @webviewNode.createShadowRoot()
    @setupWebViewAttributes()
    @setupWebViewSrcAttributeMutationObserver()
    @setupFocusPropagation()
    @setupWebviewNodeProperties()

    @viewInstanceId = getNextId()

    # UPSTREAM: new WebViewEvents(this, this.viewInstanceId);
    guestViewInternal.registerEvents this, @viewInstanceId

    shadowRoot.appendChild @browserPluginNode

  createBrowserPluginNode: ->
    # We create BrowserPlugin as a custom element in order to observe changes
    # to attributes synchronously.
    browserPluginNode = new WebView.BrowserPlugin()
    v8Util.setHiddenValue browserPluginNode, 'internal', this
    browserPluginNode

  getGuestInstanceId: ->
    @guestInstanceId

  # Resets some state upon reattaching <webview> element to the DOM.
  reset: ->
    # If guestInstanceId is defined then the <webview> has navigated and has
    # already picked up a partition ID. Thus, we need to reset the initialization
    # state. However, it may be the case that beforeFirstNavigation is false BUT
    # guestInstanceId has yet to be initialized. This means that we have not
    # heard back from createGuest yet. We will not reset the flag in this case so
    # that we don't end up allocating a second guest.
    if @guestInstanceId
      # FIXME
      guestViewInternal.destroyGuest @guestInstanceId
      @guestInstanceId = undefined
      @beforeFirstNavigation = true
      @attributes[webViewConstants.ATTRIBUTE_PARTITION].validPartitionId = true
      @contentWindow = null
    @internalInstanceId = 0

  # Sets the <webview>.request property.
  setRequestPropertyOnWebViewNode: (request) ->
    Object.defineProperty @webviewNode, 'request', value: request, enumerable: true

  setupFocusPropagation: ->
    unless @webviewNode.hasAttribute 'tabIndex'
      # <webview> needs a tabIndex in order to be focusable.
      # TODO(fsamuel): It would be nice to avoid exposing a tabIndex attribute
      # to allow <webview> to be focusable.
      # See http://crbug.com/231664.
      @webviewNode.setAttribute 'tabIndex', -1
    @webviewNode.addEventListener 'focus', (e) =>
      # Focus the BrowserPlugin when the <webview> takes focus.
      @browserPluginNode.focus()
    @webviewNode.addEventListener 'blur', (e) =>
      # Blur the BrowserPlugin when the <webview> loses focus.
      @browserPluginNode.blur()

  # Validation helper function for executeScript() and insertCSS().
  validateExecuteCodeCall: ->
    throw new Error(webViewConstants.ERROR_MSG_CANNOT_INJECT_SCRIPT) unless @guestInstanceId

  setupAutoSizeProperties: ->
    for attributeName in AUTO_SIZE_ATTRIBUTES
      Object.defineProperty @webviewNode, attributeName,
        get: => @attributes[attributeName].getValue()
        set: (value) => @attributes[attributeName].setValue value
        enumerable: true

  setupWebviewNodeProperties: ->
    @setupAutoSizeProperties()

    Object.defineProperty @webviewNode, webViewConstants.ATTRIBUTE_ALLOWTRANSPARENCY,
      get: => @attributes[webViewConstants.ATTRIBUTE_ALLOWTRANSPARENCY].getValue()
      set: (value) => @attributes[webViewConstants.ATTRIBUTE_ALLOWTRANSPARENCY].setValue value
      enumerable: true

    # We cannot use {writable: true} property descriptor because we want a
    # dynamic getter value.
    Object.defineProperty @webviewNode, 'contentWindow',
      get: =>
        return @contentWindow if @contentWindow?
        window.console.error webViewConstants.ERROR_MSG_CONTENTWINDOW_NOT_AVAILABLE
      # No setter.
      enumerable: true

    Object.defineProperty @webviewNode, webViewConstants.ATTRIBUTE_PARTITION,
      get: => @attributes[webViewConstants.ATTRIBUTE_PARTITION].getValue()
      set: (value) => @attributes[webViewConstants.ATTRIBUTE_PARTITION].setValue value
      enumerable: true

    Object.defineProperty @webviewNode, webViewConstants.ATTRIBUTE_SRC,
      get: => @attributes[webViewConstants.ATTRIBUTE_SRC].getValue()
      set: (value) => @attributes[webViewConstants.ATTRIBUTE_SRC].setValue value
      enumerable: true

    Object.defineProperty @webviewNode, webViewConstants.ATTRIBUTE_HTTPREFERRER,
      get: => @attributes[webViewConstants.ATTRIBUTE_HTTPREFERRER].getValue()
      set: (value) => @attributes[webViewConstants.ATTRIBUTE_HTTPREFERRER].setValue value
      enumerable: true

  # The purpose of this mutation observer is to catch assignment to the src
  # attribute without any changes to its value. This is useful in the case
  # where the webview guest has crashed and navigating to the same address
  # spawns off a new process.
  setupWebViewSrcAttributeMutationObserver: ->
    @srcAndPartitionObserver = new MutationObserver (mutations) =>
      for mutation in mutations
        oldValue = mutation.oldValue
        newValue = @attributes[mutation.attributeName].getValue()
        return if oldValue isnt newValue
        @handleWebviewAttributeMutation mutation.attributeName, oldValue, newValue
    params =
      attributes: true,
      attributeOldValue: true,
      attributeFilter: [
        webViewConstants.ATTRIBUTE_SRC
        webViewConstants.ATTRIBUTE_PARTITION
        webViewConstants.ATTRIBUTE_HTTPREFERRER
      ]
    @srcAndPartitionObserver.observe @webviewNode, params

  # This observer monitors mutations to attributes of the <webview> and
  # updates the BrowserPlugin properties accordingly. In turn, updating
  # a BrowserPlugin property will update the corresponding BrowserPlugin
  # attribute, if necessary. See BrowserPlugin::UpdateDOMAttribute for more
  # details.
  handleWebviewAttributeMutation: (attributeName, oldValue, newValue) ->
    # Certain changes (such as internally-initiated changes) to attributes should
    # not be handled normally.
    if @attributes[attributeName]?.ignoreNextMutation
      @attributes[attributeName].ignoreNextMutation = false
      return

    if attributeName in AUTO_SIZE_ATTRIBUTES
      return unless @guestInstanceId
      guestViewInternal.setAutoSize @guestInstanceId,
        enableAutoSize: @attributes[webViewConstants.ATTRIBUTE_AUTOSIZE].getValue(),
        min:
          width: parseInt @attributes[webViewConstants.ATTRIBUTE_MINWIDTH].getValue() || 0
          height: parseInt @attributes[webViewConstants.ATTRIBUTE_MINHEIGHT].getValue() || 0
        max:
          width: parseInt @attributes[webViewConstants.ATTRIBUTE_MAXWIDTH].getValue() || 0
          height: parseInt @attributes[webViewConstants.ATTRIBUTE_MAXHEIGHT].getValue() || 0
    else if attributeName is webViewConstants.ATTRIBUTE_ALLOWTRANSPARENCY
      # We treat null attribute (attribute removed) and the empty string as
      # one case.
      oldValue ?= ''
      newValue ?= ''

      return if oldValue is newValue and not @guestInstanceId

      guestViewInternal.setAllowTransparency @guestInstanceId, @attributes[webViewConstants.ATTRIBUTE_ALLOWTRANSPARENCY].getValue()
    else if attributeName is webViewConstants.ATTRIBUTE_HTTPREFERRER
      oldValue ?= ''
      newValue ?= ''

      if newValue == '' and oldValue != ''
        @webviewNode.setAttribute webViewConstants.ATTRIBUTE_HTTPREFERRER, oldValue

      @attributes[webViewConstants.ATTRIBUTE_HTTPREFERRER].setValue newValue

      # If the httpreferrer changes treat it as though the src changes and reload
      # the page with the new httpreferrer.
      @parseSrcAttribute()
    else if attributeName is webViewConstants.ATTRIBUTE_SRC
      # We treat null attribute (attribute removed) and the empty string as
      # one case.
      oldValue ?= ''
      newValue ?= ''
      # Once we have navigated, we don't allow clearing the src attribute.
      # Once <webview> enters a navigated state, it cannot return to a
      # placeholder state.
      if newValue == '' and oldValue != ''
        # src attribute changes normally initiate a navigation. We suppress
        # the next src attribute handler call to avoid reloading the page
        # on every guest-initiated navigation.
        @ignoreNextSrcAttributeChange = true
        @webviewNode.setAttribute webViewConstants.ATTRIBUTE_SRC, oldValue
        return

      if @ignoreNextSrcAttributeChange
        # Don't allow the src mutation observer to see this change.
        @srcAndPartitionObserver.takeRecords()
        @ignoreNextSrcAttributeChange = false
        return
      @parseSrcAttribute()
    else if attributeName is webViewConstants.ATTRIBUTE_PARTITION
      @attributes[webViewConstants.ATTRIBUTE_PARTITION].handleMutation oldValue, newValue

  handleBrowserPluginAttributeMutation: (attributeName, oldValue, newValue) ->
    if attributeName is webViewConstants.ATTRIBUTE_INTERNALINSTANCEID and !oldValue and !!newValue
      @browserPluginNode.removeAttribute webViewConstants.ATTRIBUTE_INTERNALINSTANCEID
      @internalInstanceId = parseInt newValue

      if !!@guestInstanceId and @guestInstanceId != 0
        isNewWindow = if @deferredAttachState then @deferredAttachState.isNewWindow else false
        params = @buildAttachParams isNewWindow
        guestViewInternal.attachGuest @internalInstanceId, @guestInstanceId, params, (w) => @contentWindow = w

  onSizeChanged: (webViewEvent) ->
    newWidth = webViewEvent.newWidth
    newHeight = webViewEvent.newHeight

    node = @webviewNode

    width = node.offsetWidth
    height = node.offsetHeight

    # Check the current bounds to make sure we do not resize <webview>
    # outside of current constraints.
    if node.hasAttribute(webViewConstants.ATTRIBUTE_MAXWIDTH) and
       node[webViewConstants.ATTRIBUTE_MAXWIDTH]
      maxWidth = node[webViewConstants.ATTRIBUTE_MAXWIDTH]
    else
      maxWidth = width

    if node.hasAttribute(webViewConstants.ATTRIBUTE_MINWIDTH) and
       node[webViewConstants.ATTRIBUTE_MINWIDTH]
      minWidth = node[webViewConstants.ATTRIBUTE_MINWIDTH]
    else
      minWidth = width
    minWidth = maxWidth if minWidth > maxWidth

    if node.hasAttribute(webViewConstants.ATTRIBUTE_MAXHEIGHT) and
       node[webViewConstants.ATTRIBUTE_MAXHEIGHT]
      maxHeight = node[webViewConstants.ATTRIBUTE_MAXHEIGHT]
    else
      maxHeight = height

    if node.hasAttribute(webViewConstants.ATTRIBUTE_MINHEIGHT) and
       node[webViewConstants.ATTRIBUTE_MINHEIGHT]
      minHeight = node[webViewConstants.ATTRIBUTE_MINHEIGHT]
    else
      minHeight = height
    minHeight = maxHeight if minHeight > maxHeight

    if not @attributes[webViewConstants.ATTRIBUTE_AUTOSIZE].getValue() or
       (newWidth >= minWidth and
        newWidth <= maxWidth and
        newHeight >= minHeight and
        newHeight <= maxHeight)
      node.style.width = newWidth + 'px'
      node.style.height = newHeight + 'px'
      # Only fire the DOM event if the size of the <webview> has actually
      # changed.
      @dispatchEvent webViewEvent

  # Returns if <object> is in the render tree.
  isPluginInRenderTree: ->
    !!@internalInstanceId && @internalInstanceId != 0

  hasNavigated: ->
    not @beforeFirstNavigation

  parseSrcAttribute: ->
    if not @attributes[webViewConstants.ATTRIBUTE_PARTITION].validPartitionId or
       not @attributes[webViewConstants.ATTRIBUTE_SRC].getValue()
      return

    unless @guestInstanceId?
      if @beforeFirstNavigation
        @beforeFirstNavigation = false
        @createGuest()
      return

    # Navigate to |this.src|.
    httpreferrer = @attributes[webViewConstants.ATTRIBUTE_HTTPREFERRER].getValue()
    urlOptions = if httpreferrer then {httpreferrer} else {}
    remote.getGuestWebContents(@guestInstanceId).loadUrl @attributes[webViewConstants.ATTRIBUTE_SRC].getValue(), urlOptions

  parseAttributes: ->
    return unless @elementAttached
    hasNavigated = @hasNavigated()
    @parseSrcAttribute()

  createGuest: ->
    return if @pendingGuestCreation
    params =
      storagePartitionId: @attributes[webViewConstants.ATTRIBUTE_PARTITION].getValue()
      nodeIntegration: @webviewNode.hasAttribute webViewConstants.ATTRIBUTE_NODEINTEGRATION
      plugins: @webviewNode.hasAttribute webViewConstants.ATTRIBUTE_PLUGINS
    if @webviewNode.hasAttribute webViewConstants.ATTRIBUTE_PRELOAD
      preload = @webviewNode.getAttribute webViewConstants.ATTRIBUTE_PRELOAD
      # Get the full path.
      a = document.createElement 'a'
      a.href = preload
      params.preload = a.href
      # Only support file: or asar: protocol.
      protocol = params.preload.substr 0, 5
      unless protocol in ['file:', 'asar:']
        delete params.preload
        console.error webViewConstants.ERROR_MSG_INVALID_PRELOAD_ATTRIBUTE
    guestViewInternal.createGuest 'webview', params, (guestInstanceId) =>
      @pendingGuestCreation = false
      unless @elementAttached
        guestViewInternal.destroyGuest guestInstanceId
        return
      @attachWindow guestInstanceId, false
    @pendingGuestCreation = true

  dispatchEvent: (webViewEvent) ->
    @webviewNode.dispatchEvent webViewEvent

  # Adds an 'on<event>' property on the webview, which can be used to set/unset
  # an event handler.
  setupEventProperty: (eventName) ->
    propertyName = 'on' + eventName.toLowerCase()
    Object.defineProperty @webviewNode, propertyName,
      get: => @on[propertyName]
      set: (value) =>
        if @on[propertyName]
          @webviewNode.removeEventListener eventName, @on[propertyName]
        @on[propertyName] = value
        if value
          @webviewNode.addEventListener eventName, value
      enumerable: true

  # Updates state upon loadcommit.
  onLoadCommit: (@baseUrlForDataUrl, @currentEntryIndex, @entryCount, @processId, url, isTopLevel) ->
    oldValue = @webviewNode.getAttribute webViewConstants.ATTRIBUTE_SRC
    newValue = url
    if isTopLevel and (oldValue != newValue)
      # Touching the src attribute triggers a navigation. To avoid
      # triggering a page reload on every guest-initiated navigation,
      # we use the flag ignoreNextSrcAttributeChange here.
      this.ignoreNextSrcAttributeChange = true
      this.webviewNode.setAttribute webViewConstants.ATTRIBUTE_SRC, newValue

  onAttach: (storagePartitionId) ->
    @attributes[webViewConstants.ATTRIBUTE_PARTITION].setValue storagePartitionId

  buildAttachParams: (isNewWindow) ->
    allowtransparency: @attributes[webViewConstants.ATTRIBUTE_ALLOWTRANSPARENCY].getValue()
    autosize: @attributes[webViewConstants.ATTRIBUTE_AUTOSIZE].getValue()
    instanceId: @viewInstanceId
    maxheight: parseInt @attributes[webViewConstants.ATTRIBUTE_MAXHEIGHT].getValue() || 0
    maxwidth: parseInt @attributes[webViewConstants.ATTRIBUTE_MAXWIDTH].getValue() || 0
    minheight: parseInt @attributes[webViewConstants.ATTRIBUTE_MINHEIGHT].getValue() || 0
    minwidth: parseInt @attributes[webViewConstants.ATTRIBUTE_MINWIDTH].getValue() || 0
    # We don't need to navigate new window from here.
    src: if isNewWindow then undefined else @attributes[webViewConstants.ATTRIBUTE_SRC].getValue()
    # If we have a partition from the opener, that will also be already
    # set via this.onAttach().
    storagePartitionId: @attributes[webViewConstants.ATTRIBUTE_PARTITION].getValue()
    userAgentOverride: @userAgentOverride
    httpreferrer: @attributes[webViewConstants.ATTRIBUTE_HTTPREFERRER].getValue()

  attachWindow: (guestInstanceId, isNewWindow) ->
    @guestInstanceId = guestInstanceId
    params = @buildAttachParams isNewWindow

    unless @isPluginInRenderTree()
      @deferredAttachState = isNewWindow: isNewWindow
      return true

    @deferredAttachState = null
    guestViewInternal.attachGuest @internalInstanceId, @guestInstanceId, params, (w) => @contentWindow = w

# Registers browser plugin <object> custom element.
registerBrowserPluginElement = ->
  proto = Object.create HTMLObjectElement.prototype

  proto.createdCallback = ->
    @setAttribute 'type', 'application/browser-plugin'
    @setAttribute 'id', 'browser-plugin-' + getNextId()
    # The <object> node fills in the <webview> container.
    @style.width = '100%'
    @style.height = '100%'

  proto.attributeChangedCallback = (name, oldValue, newValue) ->
    internal = v8Util.getHiddenValue this, 'internal'
    return unless internal
    internal.handleBrowserPluginAttributeMutation name, oldValue, newValue

  proto.attachedCallback = ->
    # Load the plugin immediately.
    unused = this.nonExistentAttribute

  WebView.BrowserPlugin = webFrame.registerEmbedderCustomElement 'browserplugin',
    extends: 'object', prototype: proto

  delete proto.createdCallback
  delete proto.attachedCallback
  delete proto.detachedCallback
  delete proto.attributeChangedCallback

# Registers <webview> custom element.
registerWebViewElement = ->
  proto = Object.create HTMLObjectElement.prototype

  proto.createdCallback = ->
    new WebView(this)

  proto.attributeChangedCallback = (name, oldValue, newValue) ->
    internal = v8Util.getHiddenValue this, 'internal'
    return unless internal
    internal.handleWebviewAttributeMutation name, oldValue, newValue

  proto.detachedCallback = ->
    internal = v8Util.getHiddenValue this, 'internal'
    return unless internal
    internal.elementAttached = false
    internal.reset()

  proto.attachedCallback = ->
    internal = v8Util.getHiddenValue this, 'internal'
    return unless internal
    unless internal.elementAttached
      internal.elementAttached = true
      internal.parseAttributes()

  # Public-facing API methods.
  methods = [
    "getUrl"
    "getTitle"
    "isLoading"
    "isWaitingForResponse"
    "stop"
    "reload"
    "reloadIgnoringCache"
    "canGoBack"
    "canGoForward"
    "canGoToOffset"
    "goBack"
    "goForward"
    "goToIndex"
    "goToOffset"
    "isCrashed"
    "setUserAgent"
    "executeJavaScript"
    "insertCSS"
    "openDevTools"
    "closeDevTools"
    "isDevToolsOpened"
    "send"
    "getId"
  ]

  # Forward proto.foo* method calls to WebView.foo*.
  createHandler = (m) ->
    (args...) ->
      internal = v8Util.getHiddenValue this, 'internal'
      remote.getGuestWebContents(internal.guestInstanceId)[m]  args...
  proto[m] = createHandler m for m in methods

  window.WebView = webFrame.registerEmbedderCustomElement 'webview',
    prototype: proto

  # Delete the callbacks so developers cannot call them and produce unexpected
  # behavior.
  delete proto.createdCallback
  delete proto.attachedCallback
  delete proto.detachedCallback
  delete proto.attributeChangedCallback

useCapture = true
listener = (event) ->
  return if document.readyState == 'loading'
  registerBrowserPluginElement()
  registerWebViewElement()
  window.removeEventListener event.type, listener, useCapture
window.addEventListener 'readystatechange', listener, true

module.exports = WebView

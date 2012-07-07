#
# This implements link hinting. Typing "F" will enter link-hinting mode, where all clickable items on the
# page have a hint marker displayed containing a sequence of letters. Typing those letters will select a link.
#
# In our 'default' mode, the characters we use to show link hints are a user-configurable option. By default
# they're the home row.  The CSS which is used on the link hints is also a configurable option.
#
# In 'filter' mode, our link hints are numbers, and the user can narrow down the range of possibilities by
# typing the text of the link itself.
#
LinkHints =
  hintMarkers: []
  hintMarkerContainingDiv: null
  shouldOpenInNewTab: false
  shouldOpenWithQueue: false
  # function that does the appropriate action on the selected link
  linkActivator: undefined
  # While in delayMode, all keypresses have no effect.
  delayMode: false
  # Handle the link hinting marker generation and matching. Must be initialized after settings have been
  # loaded, so that we can retrieve the option setting.
  markerMatcher: undefined
  # lock to ensure only one instance runs at a time
  isActive: false

  #
  # To be called after linkHints has been generated from linkHintsBase.
  #
  init: ->
    @onKeyDownInMode = @onKeyDownInMode.bind(this)
    @markerMatcher = if settings.get("filterLinkHints") then filterHints else alphabetHints

  #
  # Generate an XPath describing what a clickable element is.
  # The final expression will be something like "//button | //xhtml:button | ..."
  # We use translate() instead of lower-case() because Chrome only supports XPath 1.0.
  #
  clickableElementsXPath: DomUtils.makeXPath(
      ["a", "area[@href]", "textarea", "button", "select",
       "input[not(@type='hidden' or @disabled or @readonly)]",
       "*[@onclick or @tabindex or @role='link' or @role='button' or contains(@class, 'button') or " +
       "@contenteditable='' or translate(@contenteditable, 'TRUE', 'true')='true']"])

  # We need this as a top-level function because our command system doesn't yet support arguments.
  activateModeToOpenInNewTab: -> @activateMode(true, false, false)
  activateModeToCopyLinkUrl: -> @activateMode(null, false, true)
  activateModeWithQueue: -> @activateMode(true, true, false)

  activateMode: (openInNewTab, withQueue, copyLinkUrl) ->
    if @isActive
      return
    @isActive = true

    if (!document.getElementById("vimiumLinkHintCss"))
      # linkHintCss is declared by vimiumFrontend.js and contains the user supplied css overrides.
      addCssToPage(linkHintCss, "vimiumLinkHintCss")
    @setOpenLinkMode(openInNewTab, withQueue, copyLinkUrl)
    @buildLinkHints()
    # handlerStack is declared by vimiumFrontend.js
    handlerStack.push({
      keydown: @onKeyDownInMode,
      # trap all key events
      keypress: -> false
      keyup: -> false
    })

  setOpenLinkMode: (openInNewTab, withQueue, copyLinkUrl) ->
    @shouldOpenInNewTab = openInNewTab
    @shouldOpenWithQueue = withQueue

    if (openInNewTab || withQueue)
      if (openInNewTab)
        HUD.show("Open link in new tab")
      else if (withQueue)
        HUD.show("Open multiple links in a new tab")
      @linkActivator = (link) ->
        # When "clicking" on a link, dispatch the event with the appropriate meta key (CMD on Mac, CTRL on windows)
        # to open it in a new tab if necessary.
        DomUtils.simulateClick(link, {
          metaKey: KeyboardUtils.platform == "Mac",
          ctrlKey: KeyboardUtils.platform != "Mac" })
    else if (copyLinkUrl)
      HUD.show("Copy link URL to Clipboard")
      @linkActivator = (link) ->
        chrome.extension.sendRequest({handler: "copyToClipboard", data: link.href})
    else
      HUD.show("Open link in current tab")
      # When we're opening the link in the current tab, don't navigate to the selected link immediately
      # we want to give the user some time to notice which link has received focus.
      @linkActivator = (link) -> setTimeout(DomUtils.simulateClick.bind(DomUtils, link), 400)

  #
  # Builds and displays link hints for every visible clickable item on the page.
  #
  buildLinkHints: ->
    visibleElements = @getVisibleClickableElements()
    @hintMarkers = @markerMatcher.getHintMarkers(visibleElements)

    # Note(philc): Append these markers as top level children instead of as child nodes to the link itself,
    # because some clickable elements cannot contain children, e.g. submit buttons. This has the caveat
    # that if you scroll the page and the link has position=fixed, the marker will not stay fixed.
    # Also note that adding these nodes to document.body all at once is significantly faster than one-by-one.
    @hintMarkerContainingDiv = document.createElement("div")
    @hintMarkerContainingDiv.id = "vimiumHintMarkerContainer"
    @hintMarkerContainingDiv.className = "vimiumReset"
    @hintMarkerContainingDiv.appendChild(marker) for marker in @hintMarkers

    # sometimes this is triggered before documentElement is created
    # TODO(int3): fail more gracefully?
    if (document.documentElement)
      document.documentElement.appendChild(@hintMarkerContainingDiv)
    else
      @deactivateMode()

  #
  # Returns all clickable elements that are not hidden and are in the current viewport.
  # We prune invisible elements partly for performance reasons, but moreso it's to decrease the number
  # of digits needed to enumerate all of the links on screen.
  #
  getVisibleClickableElements: ->
    resultSet = DomUtils.evaluateXPath(@clickableElementsXPath, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE)

    visibleElements = []

    # Find all visible clickable elements.
    for i in [0...resultSet.snapshotLength] by 1
      element = resultSet.snapshotItem(i)
      clientRect = DomUtils.getVisibleClientRect(element, clientRect)
      if (clientRect != null)
        visibleElements.push({element: element, rect: clientRect})

      if (element.localName == "area")
        map = element.parentElement
        continue unless map
        img = document.querySelector("img[usemap='#" + map.getAttribute("name") + "']")
        continue unless img
        imgClientRects = img.getClientRects()
        continue if (imgClientRects.length == 0)
        c = element.coords.split(/,/)
        coords = [parseInt(c[0], 10), parseInt(c[1], 10), parseInt(c[2], 10), parseInt(c[3], 10)]
        rect = {
          top: imgClientRects[0].top + coords[1],
          left: imgClientRects[0].left + coords[0],
          right: imgClientRects[0].left + coords[2],
          bottom: imgClientRects[0].top + coords[3],
          width: coords[2] - coords[0],
          height: coords[3] - coords[1]
        }

        visibleElements.push({element: element, rect: rect})

    visibleElements

  #
  # Handles shift and esc keys. The other keys are passed to markerMatcher.matchHintsByKey.
  #
  onKeyDownInMode: (event) ->
    return if @delayMode

    if (event.keyCode == keyCodes.shiftKey && @shouldOpenInNewTab != null)
      # Toggle whether to open link in a new or current tab.
      @setOpenLinkMode(!@shouldOpenInNewTab, @shouldOpenWithQueue, false)
      handlerStack.push({
        keyup: (event) ->
          return if (event.keyCode != keyCodes.shiftKey)
          LinkHints.setOpenLinkMode(!LinkHints.shouldOpenInNewTab, LinkHints.shouldOpenWithQueue, false)
          handlerStack.pop()
      })

    # TODO(philc): Ignore keys that have modifiers.
    if (KeyboardUtils.isEscape(event))
      @deactivateMode()
    else
      keyResult = @markerMatcher.matchHintsByKey(event, @hintMarkers)
      linksMatched = keyResult.linksMatched
      delay = keyResult.delay ? 0
      if (linksMatched.length == 0)
        @deactivateMode()
      else if (linksMatched.length == 1)
        @activateLink(linksMatched[0], delay)
      else
        for i, marker of @hintMarkers
          @hideMarker(marker)
        for i, matched of linksMatched
          @showMarker(matched, @markerMatcher.hintKeystrokeQueue.length)
    false # We've handled this key, so prevent propagation.

  #
  # When only one link hint remains, this function activates it in the appropriate way.
  #
  activateLink: (matchedLink, delay) ->
    @delayMode = true
    clickEl = matchedLink.clickableItem
    if (DomUtils.isSelectable(clickEl))
      DomUtils.simulateSelect(clickEl)
      @deactivateMode(delay, -> LinkHints.delayMode = false)
    else
      # TODO figure out which other input elements should not receive focus
      if (clickEl.nodeName.toLowerCase() == "input" && clickEl.type != "button")
        clickEl.focus()
      DomUtils.flashRect(matchedLink.rect)
      @linkActivator(clickEl)
      if (@shouldOpenWithQueue)
        @deactivateMode delay, ->
          LinkHints.delayMode = false
          LinkHints.activateModeWithQueue()
      else
        @deactivateMode(delay, -> LinkHints.delayMode = false)

  #
  # Shows the marker, highlighting matchingCharCount characters.
  #
  showMarker: (linkMarker, matchingCharCount) ->
    linkMarker.style.display = ""
    # TODO(philc): 
    for j in [0...linkMarker.childNodes.length]
      if (j < matchingCharCount)
        linkMarker.childNodes[j].classList.add("matchingCharacter")
      else
        linkMarker.childNodes[j].classList.remove("matchingCharacter")

  hideMarker: (linkMarker) -> linkMarker.style.display = "none"

  #
  # If called without arguments, it executes immediately.  Othewise, it
  # executes after 'delay' and invokes 'callback' when it is finished.
  #
  deactivateMode: (delay, callback) ->
    deactivate = =>
      if (LinkHints.markerMatcher.deactivate)
        LinkHints.markerMatcher.deactivate()
      if (LinkHints.hintMarkerContainingDiv)
        LinkHints.hintMarkerContainingDiv.parentNode.removeChild(LinkHints.hintMarkerContainingDiv)
      LinkHints.hintMarkerContainingDiv = null
      LinkHints.hintMarkers = []
      handlerStack.pop()
      HUD.hide()
      @isActive = false

    # we invoke the deactivate() function directly instead of using setTimeout(callback, 0) so that
    # deactivateMode can be tested synchronously
    if (!delay)
      deactivate()
      callback() if (callback)
    else
      setTimeout(->
          deactivate()
          callback() if callback
        delay)

alphabetHints =
  hintKeystrokeQueue: []
  logXOfBase: (x, base) -> Math.log(x) / Math.log(base)

  getHintMarkers: (visibleElements) ->
    hintStrings = @hintStrings(visibleElements.length)
    hintMarkers = []
    for i in [0...visibleElements.length]
      marker = hintUtils.createMarkerFor(visibleElements[i])
      marker.hintString = hintStrings[i]
      marker.innerHTML = hintUtils.spanWrap(marker.hintString.toUpperCase())
      hintMarkers.push(marker)

    hintMarkers

  #
  # Returns a list of hint strings which will uniquely identify the given number of links. The hint strings
  # may be of different lengths.
  #
  hintStrings: (linkCount) ->
    linkHintCharacters = settings.get("linkHintCharacters")
    # Determine how many digits the link hints will require in the worst case. Usually we do not need
    # all of these digits for every link single hint, so we can show shorter hints for a few of the links.
    digitsNeeded = Math.ceil(@logXOfBase(linkCount, linkHintCharacters.length))
    # Short hints are the number of hints we can possibly show which are (digitsNeeded - 1) digits in length.
    shortHintCount = Math.floor(
        (Math.pow(linkHintCharacters.length, digitsNeeded) - linkCount) /
        linkHintCharacters.length)
    longHintCount = linkCount - shortHintCount

    hintStrings = []

    if (digitsNeeded > 1)
      for i in [0...shortHintCount]
        hintStrings.push(@numberToHintString(i, digitsNeeded - 1, linkHintCharacters))

    start = shortHintCount * linkHintCharacters.length
    for i in [start...(start + longHintCount)]
      hintStrings.push(@numberToHintString(i, digitsNeeded, linkHintCharacters))

    @shuffleHints(hintStrings, linkHintCharacters.length)

  #
  # This shuffles the given set of hints so that they're scattered -- hints starting with the same character
  # will be spread evenly throughout the array.
  #
  shuffleHints: (hints, characterSetLength) ->
    buckets = ([] for i in [0...characterSetLength] by 1)
    for hint in hints
      buckets[i % buckets.length].push(hint)
    result = []
    for bucket in buckets
      result = result.concat(bucket)
    result

  #
  # Converts a number like "8" into a hint string like "JK". This is used to sequentially generate all of
  # the hint text. The hint string will be "padded with zeroes" to ensure its length is equal to numHintDigits.
  #
  numberToHintString: (number, numHintDigits, characterSet) ->
    base = characterSet.length
    hintString = []
    remainder = 0
    loop
      remainder = number % base
      hintString.unshift(characterSet[remainder])
      number -= remainder
      number /= Math.floor(base)
      break unless number > 0

    # Pad the hint string we're returning so that it matches numHintDigits.
    # Note: the loop body changes hintString.length, so the original length must be cached!
    hintStringLength = hintString.length
    for i in [0...(numHintDigits - hintStringLength)] by 1
      hintString.unshift(characterSet[0])

    hintString.join("")

  matchHintsByKey: (event, hintMarkers) ->
    # If a shifted-character is typed, treat it as lowerase for the purposes of matching hints.
    keyChar = KeyboardUtils.getKeyChar(event).toLowerCase()

    if (event.keyCode == keyCodes.backspace || event.keyCode == keyCodes.deleteKey)
      if (!@hintKeystrokeQueue.pop())
        return { linksMatched: [] }
    else if (keyChar && settings.get("linkHintCharacters").indexOf(keyChar) >= 0)
      @hintKeystrokeQueue.push(keyChar)

    matchString = @hintKeystrokeQueue.join("")
    linksMatched = hintMarkers.filter((linkMarker) -> linkMarker.hintString.indexOf(matchString) == 0)
    { linksMatched: linksMatched }

  deactivate: -> @hintKeystrokeQueue = []

filterHints =
  hintKeystrokeQueue: []
  linkTextKeystrokeQueue: []
  labelMap: {}

  #
  # Generate a map of input element => label
  #
  generateLabelMap: ->
    labels = document.querySelectorAll("label")
    for label in labels
      forElement = label.getAttribute("for")
      if (forElement)
        labelText = label.textContent.trim()
        # remove trailing : commonly found in labels
        if (labelText[labelText.length-1] == ":")
          labelText = labelText.substr(0, labelText.length-1)
        @labelMap[forElement] = labelText

  generateHintString: (linkHintNumber) -> (linkHintNumber + 1).toString()

  generateLinkText: (element) ->
    linkText = ""
    showLinkText = false
    # toLowerCase is necessary as html documents return "IMG" and xhtml documents return "img"
    nodeName = element.nodeName.toLowerCase()

    if (nodeName == "input")
      if (@labelMap[element.id])
        linkText = @labelMap[element.id]
        showLinkText = true
      else if (element.type != "password")
        linkText = element.value
      # check if there is an image embedded in the <a> tag
    else if (nodeName == "a" && !element.textContent.trim() &&
        element.firstElementChild &&
        element.firstElementChild.nodeName.toLowerCase() == "img")
      linkText = element.firstElementChild.alt || element.firstElementChild.title
      showLinkText = true if (linkText)
    else
      linkText = element.textContent || element.innerHTML

    { text: linkText, show: showLinkText }

  renderMarker: (marker) ->
    marker.innerHTML = hintUtils.spanWrap(marker.hintString +
        (if marker.showLinkText then ": " + marker.linkText else ""))

  getHintMarkers: (visibleElements) ->
    @generateLabelMap()
    hintMarkers = []
    for visibleElement, i in visibleElements
      marker = hintUtils.createMarkerFor(visibleElement)
      marker.hintString = @generateHintString(i)
      linkTextObject = @generateLinkText(marker.clickableItem)
      marker.linkText = linkTextObject.text
      marker.showLinkText = linkTextObject.show
      @renderMarker(marker)
      hintMarkers.push(marker)

    hintMarkers

  matchHintsByKey: (event, hintMarkers) ->
    keyChar = KeyboardUtils.getKeyChar(event)
    delay = 0
    userIsTypingLinkText = false

    if (event.keyCode == keyCodes.enter)
      # activate the lowest-numbered link hint that is visible
      for marker in hintMarkers
        if (marker.style.display  != "none")
          return { linksMatched: [ marker ] }
    else if (event.keyCode == keyCodes.backspace || event.keyCode == keyCodes.deleteKey)
      # backspace clears hint key queue first, then acts on link text key queue.
      # if both queues are empty. exit hinting mode
      if (!@hintKeystrokeQueue.pop() && !@linkTextKeystrokeQueue.pop())
        return { linksMatched: [] }
    else if (keyChar)
      if (/[0-9]/.test(keyChar))
        @hintKeystrokeQueue.push(keyChar)
      else
        # since we might renumber the hints, the current hintKeyStrokeQueue
        # should be rendered invalid (i.e. reset).
        @hintKeystrokeQueue = []
        @linkTextKeystrokeQueue.push(keyChar)
        userIsTypingLinkText = true

    # at this point, linkTextKeystrokeQueue and hintKeystrokeQueue have been updated to reflect the latest
    # input. use them to filter the link hints accordingly.
    linksMatched = @filterLinkHints(hintMarkers)
    matchString = @hintKeystrokeQueue.join("")
    linksMatched = linksMatched.filter((linkMarker) ->
      !linkMarker.filtered && linkMarker.hintString.indexOf(matchString) == 0)

    if (linksMatched.length == 1 && userIsTypingLinkText)
      # In filter mode, people tend to type out words past the point
      # needed for a unique match. Hence we should avoid passing
      # control back to command mode immediately after a match is found.
      delay = 200

    { linksMatched: linksMatched, delay: delay }

  #
  # Marks the links that do not match the linkText search string with the 'filtered' DOM property. Renumbers
  # the remainder if necessary.
  #
  filterLinkHints: (hintMarkers) ->
    linksMatched = []
    linkSearchString = @linkTextKeystrokeQueue.join("")

    for linkMarker in hintMarkers
      matchedLink = linkMarker.linkText.toLowerCase().indexOf(linkSearchString.toLowerCase()) >= 0

      if (!matchedLink)
        linkMarker.filtered = true
      else
        linkMarker.filtered = false
        oldHintString = linkMarker.hintString
        linkMarker.hintString = @generateHintString(linksMatched.length)
        @renderMarker(linkMarker) if (linkMarker.hintString != oldHintString)
        linksMatched.push(linkMarker)

    linksMatched

  deactivate: (delay, callback) ->
    @hintKeystrokeQueue = []
    @linkTextKeystrokeQueue = []
    @labelMap = {}

hintUtils =
  #
  # Make each hint character a span, so that we can highlight the typed characters as you type them.
  #
  spanWrap: (hintString) ->
    innerHTML = []
    for char in hintString
      innerHTML.push("<span class='vimiumReset'>" + char + "</span>")
    innerHTML.join("")

  #
  # Creates a link marker for the given link.
  #
  createMarkerFor: (link) ->
    marker = document.createElement("div")
    marker.className = "vimiumReset internalVimiumHintMarker vimiumHintMarker"
    marker.clickableItem = link.element

    clientRect = link.rect
    marker.style.left = clientRect.left + window.scrollX + "px"
    marker.style.top = clientRect.top  + window.scrollY  + "px"

    marker.rect = link.rect

    marker

root = exports ? window
root.LinkHints = LinkHints

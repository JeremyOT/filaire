import UIKit
import SwiftTerm

// MARK: - Gestures, URLs & Pointer Interaction
extension FilaireTerminalView {
    func isMouseOrSelectionPanGesture(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return false }
        return pan !== twoFingerScrollGesture && pan !== trackpadScrollGesture
    }

    open override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
        if isMouseOrSelectionPanGesture(gestureRecognizer) {
            gestureRecognizer.delegate = self
        }
        if let twoFinger = twoFingerScrollGesture,
           gestureRecognizer !== twoFinger,
           gestureRecognizer !== pinchGesture,
           gestureRecognizer !== trackpadScrollGesture,
           !isMouseOrSelectionPanGesture(gestureRecognizer) {
            gestureRecognizer.require(toFail: twoFinger)
        }
        if let urlTap = urlTapGesture,
           let tap = gestureRecognizer as? UITapGestureRecognizer,
           tap !== urlTap,
           tap.numberOfTapsRequired == 1 && tap.numberOfTouchesRequired == 1 {
            tap.require(toFail: urlTap)
        }
    }

    internal func setupGestures() {
        // Pinch-to-zoom font scaling
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        addGestureRecognizer(pinch)
        self.pinchGesture = pinch

        // Continuous trackpad scroll support
        let trackpadScroll = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadScroll(_:)))
        trackpadScroll.allowedScrollTypesMask = .continuous
        addGestureRecognizer(trackpadScroll)
        self.trackpadScrollGesture = trackpadScroll

        // Two-finger touch drag to scroll terminal buffer / tmux window instead of selecting text
        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerDrag(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.cancelsTouchesInView = true
        twoFinger.delaysTouchesBegan = true
        twoFinger.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFinger.delegate = self
        addGestureRecognizer(twoFinger)
        self.twoFingerScrollGesture = twoFinger

        // URL tap gesture for single-tap link opening (including line-wrapped tmux pane URLs)
        let urlTap = UITapGestureRecognizer(target: self, action: #selector(handleUrlTap(_:)))
        urlTap.numberOfTapsRequired = 1
        urlTap.numberOfTouchesRequired = 1
        urlTap.cancelsTouchesInView = true
        urlTap.delegate = self
        addGestureRecognizer(urlTap)
        self.urlTapGesture = urlTap

        // Hover gesture for multi-line URL highlighting across wrapped lines
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleFilaireHover(_:)))
        addGestureRecognizer(hover)
        self.customHoverGesture = hover

        // Three-finger swipe gestures for fast tmux window navigation
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipeLeft(_:)))
        swipeLeft.direction = .left
        swipeLeft.numberOfTouchesRequired = 3
        swipeLeft.cancelsTouchesInView = true
        swipeLeft.delegate = self
        addGestureRecognizer(swipeLeft)
        self.threeFingerSwipeLeft = swipeLeft

        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipeRight(_:)))
        swipeRight.direction = .right
        swipeRight.numberOfTouchesRequired = 3
        swipeRight.cancelsTouchesInView = true
        swipeRight.delegate = self
        addGestureRecognizer(swipeRight)
        self.threeFingerSwipeRight = swipeRight

        // Require single-touch and selection gestures to wait for two-finger drag to fail
        for existing in gestureRecognizers ?? [] {
            if isMouseOrSelectionPanGesture(existing) {
                existing.delegate = self
            }
            if existing !== twoFinger, existing !== pinch, existing !== trackpadScroll,
               existing !== swipeLeft, existing !== swipeRight,
               !isMouseOrSelectionPanGesture(existing) {
                existing.require(toFail: twoFinger)
            }
            if let tap = existing as? UITapGestureRecognizer,
               tap !== urlTap,
               tap.numberOfTapsRequired == 1 && tap.numberOfTouchesRequired == 1 {
                tap.require(toFail: urlTap)
            }
        }
    }

    @objc private func handlePinchGesture(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBaseFontSize = FontManager.shared.fontSize
        case .changed:
            let targetSize = pinchBaseFontSize * gesture.scale
            let clamped = max(9.0, min(targetSize, 32.0))
            if abs(clamped - FontManager.shared.fontSize) >= 0.5 {
                clearUrlHighlight()
                FontManager.shared.fontSize = clamped
                self.font = FontManager.shared.currentFont()
            }
        case .ended, .cancelled:
            clearUrlHighlight()
            updateSizeIfNeeded()
            notifyCurrentDimensions()
        default:
            break
        }
    }

    @objc private func handleTwoFingerDrag(_ gesture: UIPanGestureRecognizer) {
        let terminal = getTerminal()
        switch gesture.state {
        case .began:
            clearUrlHighlight()
            accumulatedTwoFingerDeltaY = 0
            // Clear any text selection that might have started
            selection.selectNone()
            selection.active = false
            // Release button 1 in tmux if mouse reporting was active
            if terminal.mouseMode != .off && allowMouseReporting {
                let loc = gesture.location(in: self)
                let cellWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
                let cellHeight = max(1, bounds.height / CGFloat(max(1, terminal.rows)))
                let col = Int(loc.x / cellWidth)
                let row = Int(loc.y / cellHeight)
                terminal.sendEvent(buttonFlags: 3, x: max(0, col), y: max(0, row))
            }
        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            accumulatedTwoFingerDeltaY += translation.y

            let cellHeight = max(1, bounds.height / CGFloat(max(1, terminal.rows)))
            let cellWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
            // On high-DPI touchscreens, physical touch drag deltas accumulate quickly.
            // Require 2x finger travel distance per line to provide smooth, controlled 2-finger scrolling.
            let threshold = max(28.0, cellHeight * 2.0)

            var steps = 0
            while abs(accumulatedTwoFingerDeltaY) >= threshold && steps < 6 {
                steps += 1
                clearUrlHighlight()
                let isUp = accumulatedTwoFingerDeltaY > 0
                if isUp {
                    accumulatedTwoFingerDeltaY -= threshold
                } else {
                    accumulatedTwoFingerDeltaY += threshold
                }

                if terminal.mouseMode != .off && allowMouseReporting {
                    let loc = gesture.location(in: self)
                    let col = Int(loc.x / cellWidth)
                    let row = Int(loc.y / cellHeight)
                    // SGR mouse wheel up: 64, down: 65
                    let buttonFlag = isUp ? 64 : 65
                    terminal.sendEvent(buttonFlags: buttonFlag, x: max(0, col), y: max(0, row))
                } else {
                    if isUp {
                        scrollUp(lines: 1)
                    } else {
                        scrollDown(lines: 1)
                    }
                }
            }
            if abs(accumulatedTwoFingerDeltaY) >= threshold {
                accumulatedTwoFingerDeltaY = 0
            }
            selection.selectNone()
            selection.active = false
        case .ended, .cancelled:
            accumulatedTwoFingerDeltaY = 0
            selection.selectNone()
            selection.active = false
        default:
            break
        }
    }

    @objc private func handleTrackpadScroll(_ gesture: UIPanGestureRecognizer) {
        let terminal = getTerminal()
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        accumulatedScrollDeltaY += translation.y
        let threshold: CGFloat = 12.0

        if abs(accumulatedScrollDeltaY) >= threshold {
            clearUrlHighlight()
            let isUp = accumulatedScrollDeltaY > 0
            if terminal.mouseMode != .off && allowMouseReporting {
                let loc = gesture.location(in: self)
                let cellWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
                let cellHeight = max(1, bounds.height / CGFloat(max(1, terminal.rows)))
                let col = Int(loc.x / cellWidth)
                let row = Int(loc.y / cellHeight)
                // SGR mouse wheel up: 64, down: 65
                let buttonFlag = isUp ? 64 : 65
                terminal.sendEvent(buttonFlags: buttonFlag, x: max(0, col), y: max(0, row))
            } else {
                if isUp {
                    scrollUp(lines: 1)
                } else {
                    scrollDown(lines: 1)
                }
            }
            accumulatedScrollDeltaY = 0
        }
    }


    // MARK: - URL Tap & Pane Wrap Expansion

    public func cellDimension() -> CGSize {
        let scale = contentScaleFactor > 0 ? contentScaleFactor : (window?.screen.scale ?? UIScreen.main.scale)
        if let cached = cachedCellDimension, cached.font == font, cached.scale == scale {
            return cached.size
        }
        let font = self.font
        let ctFont = font as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        let cellHeight = ceil(ascent + descent + leading)
        let cellWidth = "W".size(withAttributes: [.font: font]).width
        let snappedWidth = max(1, (cellWidth * scale).rounded() / scale)
        let snappedHeight = max(1, ceil(cellHeight * scale) / scale)
        let size = CGSize(width: snappedWidth, height: snappedHeight)
        cachedCellDimension = (font, scale, size)
        return size
    }

    public func gridPosition(for point: CGPoint) -> Position {
        let dim = cellDimension()
        let col = Int(point.x / dim.width)
        let row = Int(point.y / dim.height)
        let terminal = getTerminal()
        let clampedCol = max(0, min(terminal.cols - 1, col))
        let clampedRow = max(0, min(terminal.rows - 1, row))
        return Position(col: clampedCol, row: clampedRow)
    }

    public func expandUrlIfWrapped(link: String) -> String {
        TerminalUrlDetector.expandUrlIfWrapped(link: link, in: getTerminal())
    }

    @objc private func handleUrlTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        clearUrlHighlight()
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        let point = gesture.location(in: self)
        let gridPos = gridPosition(for: point)
        if let url = TerminalUrlDetector.detectUrl(at: gridPos.col, row: gridPos.row, in: getTerminal()) {
            terminalDelegate?.requestOpenLink(source: self, link: url, params: [Self.detectedUrlParamKey: "1"])
        }
    }


    // MARK: - UIGestureRecognizerDelegate

    open override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === threeFingerSwipeLeft || gestureRecognizer === threeFingerSwipeRight {
            return autoConnectTmux
        }
        if gestureRecognizer === urlTapGesture {
            let point = gestureRecognizer.location(in: self)
            let gridPos = gridPosition(for: point)
            return TerminalUrlDetector.detectUrl(at: gridPos.col, row: gridPos.row, in: getTerminal()) != nil
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleThreeFingerSwipeLeft(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended, autoConnectTmux else { return }
        if triggerTmuxNextWindow() {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    @objc private func handleThreeFingerSwipeRight(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended, autoConnectTmux else { return }
        if triggerTmuxPrevWindow() {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        currentTouchType = touch.type
        if gestureRecognizer === twoFingerScrollGesture {
            return touch.type == .direct
        }
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === twoFingerScrollGesture {
            if currentTouchType != .direct {
                return false
            }
            if otherGestureRecognizer is UIPinchGestureRecognizer ||
               otherGestureRecognizer is UISwipeGestureRecognizer ||
               otherGestureRecognizer === trackpadScrollGesture {
                return false
            }
            return true
        }
        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if otherGestureRecognizer === twoFingerScrollGesture {
            if currentTouchType != .direct {
                return false
            }
            if gestureRecognizer is UIPinchGestureRecognizer ||
               gestureRecognizer is UISwipeGestureRecognizer ||
               gestureRecognizer === trackpadScrollGesture {
                return false
            }
            return true
        }
        return false
    }

    // MARK: - Multi-line URL Hover Highlighting

    @objc private func handleFilaireHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let point = gesture.location(in: self)
            let gridPos = gridPosition(for: point)
            guard gridPos != lastHoverGridPosition else { return }
            lastHoverGridPosition = gridPos
            let match = TerminalUrlDetector.detectUrlMatch(at: gridPos.col, row: gridPos.row, in: getTerminal())

            if match != currentHoveredMatch {
                currentHoveredMatch = match
                renderUrlHighlight(match: match)
            }
        case .ended, .cancelled:
            clearUrlHighlight()
        default:
            break
        }
    }

    public func clearUrlHighlight() {
        if currentHoveredMatch != nil || urlHighlightLayer.path != nil {
            currentHoveredMatch = nil
            urlHighlightLayer.path = nil
            urlUnderlineLayer.path = nil
            lastHoverGridPosition = nil
        }
        lastHoverGridPosition = nil
    }

    public func wipeScreen() {
        escapeSequenceFilter.reset()
        feed(byteArray: [0x1B, UInt8(ascii: "c")][...])
        clearUrlHighlight()
    }

    public func resetParserState() {
        escapeSequenceFilter.reset()
    }

    private func renderUrlHighlight(match: DetectedUrlMatch?) {
        guard let match = match, !match.segments.isEmpty else {
            clearUrlHighlight()
            return
        }

        let dim = cellDimension()
        let bgPath = UIBezierPath()
        let underlinePath = UIBezierPath()

        for segment in match.segments {
            let x = CGFloat(segment.colRange.lowerBound) * dim.width
            let width = CGFloat(segment.colRange.count) * dim.width
            let y = CGFloat(segment.row) * dim.height
            let height = dim.height

            // 1. Subtle rounded background highlight for all lines of the URL
            let rect = CGRect(x: x, y: y, width: width, height: height)
            bgPath.append(UIBezierPath(roundedRect: rect, cornerRadius: 2))

            // 2. Underline spanning the full width of every line segment
            let underlineY = y + height - 1.0
            underlinePath.move(to: CGPoint(x: x, y: underlineY))
            underlinePath.addLine(to: CGPoint(x: x + width, y: underlineY))
        }

        urlHighlightLayer.path = bgPath.cgPath
        urlUnderlineLayer.path = underlinePath.cgPath
    }

    // MARK: - Pointer Interaction (I-Beam Cursor & URL Pointer)



    internal func setupCustomPointerInteraction() {
        let delegate = FilairePointerDelegate(terminalView: self)
        self.filairePointerDelegate = delegate
        let interaction = UIPointerInteraction(delegate: delegate)
        addInteraction(interaction)
        self.filairePointerInteraction = interaction
    }

    public func pointerStyle(for region: UIPointerRegion) -> UIPointerStyle? {
        if let id = region.identifier as? String, id == "url" {
            // Over links, yield to standard pointer to signal clickability
            return nil
        }
        let dim = cellDimension()
        let beamHeight = max(12.0, min(dim.height, 36.0))
        return UIPointerStyle(shape: .verticalBeam(length: beamHeight))
    }


}

private final class FilairePointerDelegate: NSObject, UIPointerInteractionDelegate {
    private weak var terminalView: FilaireTerminalView?
    private var lastRegionKey: (col: Int, row: Int, bounds: CGRect)?
    private var lastRegion: UIPointerRegion?

    init(terminalView: FilaireTerminalView) {
        self.terminalView = terminalView
        super.init()
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard let view = terminalView, view.bounds.contains(request.location) else { return nil }

        let gridPos = view.gridPosition(for: request.location)
        if let key = lastRegionKey, key.col == gridPos.col, key.row == gridPos.row, key.bounds == view.bounds,
           let region = lastRegion {
            return region
        }

        let region: UIPointerRegion
        if TerminalUrlDetector.detectUrl(at: gridPos.col, row: gridPos.row, in: view.getTerminal()) != nil {
            let dim = view.cellDimension()
            let rect = CGRect(
                x: CGFloat(gridPos.col) * dim.width,
                y: CGFloat(gridPos.row) * dim.height,
                width: dim.width,
                height: dim.height
            )
            region = UIPointerRegion(rect: rect, identifier: "url")
        } else {
            region = UIPointerRegion(rect: view.bounds, identifier: "terminal")
        }

        lastRegionKey = (gridPos.col, gridPos.row, view.bounds)
        lastRegion = region
        return region
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        return terminalView?.pointerStyle(for: region)
    }
}


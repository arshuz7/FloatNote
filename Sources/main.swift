// FloatNote — an always-on-top floating scratch window for macOS.
// Holds rich text and images, floats over every app, Space and full-screen window.
// Global hotkeys (work from any app):
//   ⌃⌥C      copy the next line to the clipboard (then just ⌘V wherever you are)
//   ⌃⌥R      restart line-by-line copying from the top
//   ⌃⌥Space  show / hide the window

import Cocoa
import Carbon.HIToolbox

// MARK: - Panel

final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Make sure the standard editing shortcuts work even though this is a background (menu-bar) app.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let ch = event.charactersIgnoringModifiers?.lowercased() {
            var sel: Selector?
            if flags == .command {
                switch ch {
                case "c": sel = #selector(NSText.copy(_:))
                case "v": sel = #selector(NSText.paste(_:))
                case "x": sel = #selector(NSText.cut(_:))
                case "a": sel = #selector(NSText.selectAll(_:))
                case "z": sel = Selector(("undo:"))
                case "w": orderOut(nil); return true
                default: break
                }
            } else if flags == [.command, .shift], ch == "z" {
                sel = Selector(("redo:"))
            }
            if let s = sel, NSApp.sendAction(s, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Background (only this fades; text and images stay solid)

final class BackgroundView: NSView {
    var fill: CGFloat = 1 { didSet { needsDisplay = true } }
    override var mouseDownCanMoveWindow: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        // Little grab handle at the top so it's obvious where to drag
        let handle = NSRect(x: bounds.midX - 18, y: bounds.maxY - 11, width: 36, height: 4)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSTextStorageDelegate {
    var panel: FloatPanel!
    var background: BackgroundView!
    var textView: NSTextView!
    var statusLabel: NSTextField!
    var statusItem: NSStatusItem!
    var hotKeyRefs: [EventHotKeyRef?] = []

    /// Character index where the next "copy next line" starts.
    var lineCursor = 0
    var programmaticSelection = false
    var fittingImages = false
    var naturalSizes: [ObjectIdentifier: NSSize] = [:]
    var saveWork: DispatchWorkItem?

    let defaults = UserDefaults.standard

    lazy var storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FloatNote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("content.rtfd")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildPanel()
        buildStatusItem()
        loadContent()
        registerHotKeys()
        updateStatus()
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveContent()
    }

    // MARK: Window

    func buildPanel() {
        panel = FloatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
            styleMask: [.titled, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "FloatNote"
        // No visible title bar or traffic lights — the top strip is just a drag handle.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(b)?.isHidden = true
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 240, height: 160)
        panel.center()
        panel.setFrameAutosaveName("FloatNoteWindow")   // remembers position & size

        let alpha = defaults.object(forKey: "opacity") as? Double ?? 1.0

        // Text area (rich text + images)
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        textView = (scroll.documentView as! NSTextView)
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false   // don't mangle copied code
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: baseFontSize),
                                     .foregroundColor: NSColor.textColor]

        // Bottom bar
        let nextBtn = NSButton(title: "Copy next  ⌃⌥C", target: self, action: #selector(copyNextLine))
        nextBtn.bezelStyle = .rounded
        nextBtn.controlSize = .small
        nextBtn.font = .systemFont(ofSize: 11)

        let topBtn = NSButton(title: "↺", target: self, action: #selector(restartLines))
        topBtn.bezelStyle = .rounded
        topBtn.controlSize = .small
        topBtn.toolTip = "Start again from the top (⌃⌥R)"

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let slider = NSSlider(value: alpha, minValue: 0.1, maxValue: 1.0,
                              target: self, action: #selector(opacityChanged(_:)))
        slider.controlSize = .mini
        slider.toolTip = "Background transparency (text stays solid)"
        slider.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let bar = NSStackView(views: [nextBtn, topBtn, statusLabel, slider])
        bar.orientation = .horizontal
        bar.spacing = 6

        let content = BackgroundView()
        content.fill = CGFloat(alpha)
        background = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(bar)
        panel.contentView = content

        // Start the text just below the (invisible) title bar strip, which stays draggable.
        let topConstraint: NSLayoutConstraint
        if let guide = panel.contentLayoutGuide as? NSLayoutGuide {
            topConstraint = scroll.topAnchor.constraint(equalTo: guide.topAnchor)
        } else {
            topConstraint = scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 22)
        }
        NSLayoutConstraint.activate([
            topConstraint,
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            bar.heightAnchor.constraint(equalToConstant: 22),
        ])

        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            self?.fitImages()
        }
    }

    @objc func toggleWindow() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc func opacityChanged(_ sender: NSSlider) {
        background.fill = CGFloat(sender.doubleValue)
        panel.invalidateShadow()
        defaults.set(sender.doubleValue, forKey: "opacity")
    }

    @objc func clearAll() {
        textView.textStorage?.setAttributedString(NSAttributedString())
        lineCursor = 0
        updateStatus()
        scheduleSave()
    }

    // MARK: Menus

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "pip", accessibilityDescription: "FloatNote") {
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "FN"
        }
        let menu = NSMenu()
        menu.addItem(item("Show / Hide Window   ⌃⌥Space", #selector(toggleWindow)))
        menu.addItem(item("Copy Next Line   ⌃⌥C", #selector(copyNextLine)))
        menu.addItem(item("Restart From Top   ⌃⌥R", #selector(restartLines)))
        menu.addItem(.separator())
        menu.addItem(item("Clear Everything", #selector(clearAll)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FloatNote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit FloatNote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let plain = NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(plain)
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        edit.addItem(find)
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: Line-by-line copying

    @objc func copyNextLine() {
        guard let storage = textView.textStorage else { return }
        let s = storage.string as NSString
        if lineCursor >= s.length { lineCursor = 0 }

        var loc = lineCursor
        while loc < s.length {
            let full = s.lineRange(for: NSRange(location: loc, length: 0))
            let range = trimmedLineRange(full, in: s)
            let text = s.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
            let image = firstImage(in: range)

            if text.trimmingCharacters(in: .whitespaces).isEmpty && image == nil {
                loc = NSMaxRange(full)      // skip blank lines
                continue
            }

            let pb = NSPasteboard.general
            pb.clearContents()
            if text.trimmingCharacters(in: .whitespaces).isEmpty, let img = image {
                pb.writeObjects([img])       // a line that's just an image copies the image
            } else {
                pb.setString(text, forType: .string)
            }

            programmaticSelection = true
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            if range.length > 0 { textView.showFindIndicator(for: range) }
            programmaticSelection = false

            lineCursor = NSMaxRange(full)
            updateStatus(copied: true)
            return
        }

        // Reached the end
        NSSound.beep()
        lineCursor = 0
        statusLabel.stringValue = "End reached — next copy starts at the top"
    }

    @objc func restartLines() {
        lineCursor = 0
        updateStatus()
    }

    func trimmedLineRange(_ r: NSRange, in s: NSString) -> NSRange {
        var len = r.length
        while len > 0 {
            let c = s.character(at: r.location + len - 1)
            if c == 10 || c == 13 || c == 0x2028 || c == 0x2029 { len -= 1 } else { break }
        }
        return NSRange(location: r.location, length: len)
    }

    func firstImage(in range: NSRange) -> NSImage? {
        guard let storage = textView.textStorage, range.length > 0 else { return nil }
        var found: NSImage?
        storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if let att = value as? NSTextAttachment, let img = image(for: att) {
                found = img
                stop.pointee = true
            }
        }
        return found
    }

    func updateStatus(copied: Bool = false) {
        let s = textView.string as NSString
        if s.length == 0 {
            statusLabel.stringValue = "Paste text or images here"
            return
        }
        // Peek at what the next copy will grab
        var loc = lineCursor
        var preview = ""
        while loc < s.length {
            let full = s.lineRange(for: NSRange(location: loc, length: 0))
            let t = s.substring(with: trimmedLineRange(full, in: s))
            let shown = t.replacingOccurrences(of: "\u{FFFC}", with: "🖼")
            if !shown.trimmingCharacters(in: .whitespaces).isEmpty {
                preview = shown.trimmingCharacters(in: .whitespaces)
                break
            }
            loc = NSMaxRange(full)
        }
        let prefix = copied ? "Copied ✓  Next: " : "Next: "
        statusLabel.stringValue = preview.isEmpty ? (copied ? "Copied ✓  (that was the last line)" : "End — ⌃⌥C restarts at top")
                                                  : prefix + preview
    }

    // Clicking a line makes it the next one to copy.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !programmaticSelection else { return }
        guard let type = NSApp.currentEvent?.type,
              type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged else { return }
        let s = textView.string as NSString
        let loc = min(textView.selectedRange().location, s.length)
        lineCursor = s.lineRange(for: NSRange(location: loc, length: 0)).location
        updateStatus()
    }

    func textDidChange(_ notification: Notification) {
        if lineCursor > (textView.string as NSString).length { lineCursor = 0 }
        DispatchQueue.main.async { self.fitImages() }
        updateStatus()
        scheduleSave()
    }

    // MARK: Readability — normalize pasted styling

    let baseFontSize: CGFloat = 14

    /// Runs after every edit (paste, typing, load). Strips colors and odd fonts that came from other apps,
    /// so text always uses the system font and adapts to light / dark mode. Keeps bold, italic and monospace.
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), editedRange.length > 0,
              NSMaxRange(editedRange) <= textStorage.length else { return }
        normalizeStyle(textStorage, in: editedRange)
    }

    func normalizeStyle(_ ts: NSTextStorage, in range: NSRange) {
        ts.removeAttribute(.backgroundColor, range: range)
        ts.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)

        var fonts: [(NSRange, NSFont)] = []
        ts.enumerateAttribute(.font, in: range, options: []) { value, r, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var font: NSFont = traits.contains(.monoSpace)
                ? .monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular)
                : .systemFont(ofSize: baseFontSize)
            let style = traits.intersection([.bold, .italic])
            if !style.isEmpty,
               let styled = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(style), size: font.pointSize) {
                font = styled
            }
            fonts.append((r, font))
        }
        for (r, f) in fonts { ts.addAttribute(.font, value: f, range: r) }
    }

    // MARK: Images

    func image(for att: NSTextAttachment) -> NSImage? {
        if let data = att.fileWrapper?.regularFileContents, let img = NSImage(data: data) { return img }
        if let img = att.image { return img }
        return (att.attachmentCell as? NSTextAttachmentCell)?.image
    }

    /// Shrinks big pasted images so they fit the window width (originals are kept for copying/saving).
    func fitImages() {
        guard !fittingImages, let storage = textView.textStorage, let container = textView.textContainer else { return }
        let maxW = max(60, container.size.width - container.lineFragmentPadding * 2 - 4)
        var changes: [(NSTextAttachment, NSImage, NSRange)] = []

        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let att = value as? NSTextAttachment else { return }
            let key = ObjectIdentifier(att)
            var natural = naturalSizes[key]
            var img: NSImage?
            if natural == nil {
                img = image(for: att)
                natural = img?.size
                naturalSizes[key] = natural
            }
            guard let nat = natural, nat.width > 0 else { return }
            let targetW = min(nat.width, maxW)
            let current = att.attachmentCell?.cellSize().width ?? 0
            if abs(current - targetW) < 1 { return }
            guard let source = img ?? image(for: att), let scaled = source.copy() as? NSImage else { return }
            scaled.size = NSSize(width: targetW, height: nat.height * targetW / nat.width)
            changes.append((att, scaled, range))
        }

        guard !changes.isEmpty else { return }
        fittingImages = true
        storage.beginEditing()
        for (att, scaled, range) in changes {
            att.attachmentCell = NSTextAttachmentCell(imageCell: scaled)
            storage.edited(.editedAttributes, range: range, changeInLength: 0)
        }
        storage.endEditing()
        fittingImages = false
    }

    // MARK: Persistence

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveContent() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveContent() {
        guard let storage = textView?.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        if let wrapper = try? storage.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            try? wrapper.write(to: storeURL, options: .atomic, originalContentsURL: nil)
        }
    }

    func loadContent() {
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let saved = try? NSAttributedString(url: storeURL,
                                                  options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                  documentAttributes: nil) else { return }
        textView.textStorage?.setAttributedString(saved)
        DispatchQueue.main.async { self.fitImages() }
    }

    // MARK: Global hotkeys

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.handleHotKey(hk.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        register(keyCode: kVK_ANSI_C, id: 1)   // ⌃⌥C  copy next line
        register(keyCode: kVK_ANSI_R, id: 2)   // ⌃⌥R  restart
        register(keyCode: kVK_Space,  id: 3)   // ⌃⌥Space show/hide
    }

    func register(keyCode: Int, id: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x464E_4F54), id: id) // 'FNOT'
        RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey), hkID,
                            GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }

    func handleHotKey(_ id: UInt32) {
        switch id {
        case 1: copyNextLine()
        case 2: restartLines()
        case 3: toggleWindow()
        default: break
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar app, no Dock icon
app.run()

//
//  TabBarController.swift
//  Sileo
//
//  Created by CoolStar on 4/20/20.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation
import LNPopupController

class TabBarController: UITabBarController, UITabBarControllerDelegate {
    static var singleton: TabBarController?
    private var downloadsController: UINavigationController?
    private(set) public var popupIsPresented = false
    private var popupLock = DispatchSemaphore(value: 1)
    private var shouldSelectIndex = -1
    private static let lastSelectedTabKey = "LastSelectedTab"
    private var fuckedUpSources = false
//    private let ipadModeMinWidth = CGFloat(752) //debug
    private let ipadModeMinWidth = CGFloat(768)
    
    private var popupQueueLock = DispatchSemaphore(value: 1)
    private static let popupQueueContext = 50
    private static let popupQueueKey = DispatchSpecificKey<Int>()
    private static let popupQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "Sileo.PopupQueue", qos: .userInitiated)
        queue.setSpecific(key: popupQueueKey, value: popupQueueContext)
        return queue
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        delegate = self
        TabBarController.singleton = self
        
        let savedTab = UserDefaults.standard.integer(forKey: TabBarController.lastSelectedTabKey)
        if let count = viewControllers?.count, savedTab > 0, savedTab < count {
            selectedIndex = savedTab
        }
        
        downloadsController = UINavigationController(rootViewController: DownloadManager.shared.viewController)
        downloadsController?.isNavigationBarHidden = true
        downloadsController?.popupItem.title = ""
        downloadsController?.popupItem.subtitle = ""
        
        weak var weakSelf = self
        NotificationCenter.default.addObserver(weakSelf as Any,
                                               selector: #selector(updateSileoColors),
                                               name: SileoThemeManager.sileoChangedThemeNotification,
                                               object: nil)
        updateSileoColors()
        (self.tabBar as? TabBar)?.onLayout = { [weak self] in self?.applyFloatingStyle() }
        // Install the saved item metrics before the first layout so the bar never has to resize on launch
        applyFloatingStyle()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(floatingTabBarChanged),
                                               name: Notification.Name("FloatingTabBar"),
                                               object: nil)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.tabBar.layoutIfNeeded()
        applyFloatingStyle()
        
        self.updatePopup()
    }
    
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        shouldSelectIndex = tabBarController.selectedIndex
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        // Run after the tab bar relayout, otherwise the system may rebuild the icon view and drop the animation
        DispatchQueue.main.async { [weak self] in self?.animateSelectedIcon() }
        saveSelectedTab()
        if shouldSelectIndex == tabBarController.selectedIndex {
            if let splitViewController = viewController as? UISplitViewController {
                if let navController = splitViewController.viewControllers[0] as? UINavigationController {
                    navController.popToRootViewController(animated: true)
                }
            }
        }
        if tabBarController.selectedIndex == 4 && shouldSelectIndex == 4 {
            if let navController = tabBarController.viewControllers?[4] as? SileoNavigationController,
               let packageList = navController.viewControllers[0] as? PackageListViewController {
                packageList.searchController.searchBar.becomeFirstResponder()
            }
        }
        if tabBarController.selectedIndex == 3 && shouldSelectIndex == 3 {
            if let navController = tabBarController.viewControllers?[3] as? SileoNavigationController,
               let packageList = navController.viewControllers[0] as? PackageListViewController,
               let collectionView = packageList.collectionView {
                let yVal = -1 * collectionView.adjustedContentInset.top
                collectionView.setContentOffset(CGPoint(x: 0, y: yVal), animated: true)
            }
        }
        if tabBarController.selectedIndex ==  2 && !fuckedUpSources {
            if let sourcesSVC = tabBarController.viewControllers?[2] as? UISplitViewController,
               let sourcesNaVC = sourcesSVC.viewControllers[0] as? SileoNavigationController {
                if sourcesNaVC.presentedViewController == nil {
                    sourcesNaVC.popToRootViewController(animated: false)
                }
            }
            fuckedUpSources = true
        }
        if viewController as? SileoNavigationController != nil { return }
        if viewController as? SourcesSplitViewController != nil { return }
        fatalError("View Controller mismatch")
    }
    
    // Selection can also change in code (URLs, shortcuts), so this is also called when the app goes to the background
    func saveSelectedTab() {
        UserDefaults.standard.set(selectedIndex, forKey: TabBarController.lastSelectedTabKey)
    }

    func presentPopup() {
        presentPopup(completion: nil)
    }
    
    func presentPopup(animated:Bool = true, completion: (() -> Void)?) {
        NSLog("SileoLog: TabBarController.presentPopup \(popupIsPresented), \(downloadsController), \(completion)")

        guard let downloadsController = downloadsController, !popupIsPresented else {
            if let completion = completion {
                completion()
            }
            return
        }
        
        popupLock.wait()
        defer {
            popupLock.signal()
        }
        
        popupIsPresented = true
        self.popupContentView.popupCloseButtonAutomaticallyUnobstructsTopBars = false
        self.popupBar.toolbar.tag = WHITE_BLUR_TAG
        self.popupBar.barStyle = .prominent
        
        self.updateSileoColors()
        
        self.popupBar.toolbar.setBackgroundImage(nil, forToolbarPosition: .any, barMetrics: .default)
        self.popupBar.tabBarHeight = floatingPopupTabBarHeight
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.popupBar.isInlineWithTabBar = true
            self.popupBar.tabBarHeight += 1
        }
        self.popupBar.progressViewStyle = .bottom
        self.popupInteractionStyle = .drag
                
        TabBarController.popupQueue.async {
            self.popupQueueLock.wait()
            DispatchQueue.main.async {
                self.presentPopupBar(withContentViewController: downloadsController, animated: animated) {
                    completion?()
                    self.popupQueueLock.signal()
                }
            }
        }
        
        self.updateSileoColors()
    }
    
    func dismissPopup() {
        dismissPopup(completion: nil)
    }
    
    func dismissPopup(animated:Bool = true, completion: (() -> Void)?) {
        NSLog("SileoLog: TabBarController.dismissPopup \(popupIsPresented) \(completion)")

        guard popupIsPresented else {
            if let completion = completion {
                completion()
            }
            return
        }
        
        popupLock.wait()
        defer {
            popupLock.signal()
        }
        
        popupIsPresented = false
            
        TabBarController.popupQueue.async {
            self.popupQueueLock.wait()
            DispatchQueue.main.async {
                self.dismissPopupBar(animated: animated) {
                    completion?()
                    self.popupQueueLock.signal()
                }
            }
        }
    }
    
    func presentPopupController() {
        self.presentPopupController(completion: nil)
    }
    
    func presentPopupController(completion: (() -> Void)?) {
        NSLog("SileoLog: TabBarController.presentPopupController \(completion)")

        guard popupIsPresented else {
            if let completion = completion {
                completion()
            }
            return
        }
        
        popupLock.wait()
        defer {
            popupLock.signal()
        }
        
        self.openPopup(animated: true, completion: completion)
    }
    
    // expands the popup once the modal being dismissed and the popup bar presentation are done, so the open is not dropped
    func presentPopupControllerWhenReady(retries: Int = 40) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if self.presentedViewController != nil && retries > 0 {
                self.presentPopupControllerWhenReady(retries: retries - 1)
                return
            }
            TabBarController.popupQueue.async {
                self.popupQueueLock.wait()
                self.popupQueueLock.signal()
                DispatchQueue.main.async {
                    self.presentPopupController()
                }
            }
        }
    }
    
    func dismissPopupController() {
        self.dismissPopupController(completion: nil)
    }
    
    func dismissPopupController(completion: (() -> Void)?) {
        NSLog("SileoLog: TabBarController.dismissPopupController \(completion)")

        guard popupIsPresented else {
            completion?()
            return
        }
        
        popupLock.wait()
        defer {
            popupLock.signal()
        }
        
        self.closePopup(animated: true, completion: completion)
    }
    
    func updatePopup() {
        updatePopup(completion: nil)
    }
    
    func updatePopup(animated:Bool = true, completion: (() -> Void)? = nil, bypass: Bool = false) {
        func hideRegardless() {
            if UIDevice.current.userInterfaceIdiom == .pad && self.view.frame.width >= ipadModeMinWidth {
                downloadsController?.popupItem.title = String(localizationKey: "Queued_Package_Status")
                downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), 0)
                self.dismissPopupController()
                self.presentPopup(animated: animated, completion: completion)
            } else {
                self.dismissPopup(animated: animated, completion: completion)
            }
        }
//we should never dismiss the popup if the queue is not empty (will cause TabBar to never display anymore)
//        if bypass {
//            hideRegardless()
//            return
//        }
        
        let manager = DownloadManager.shared
        NSLog("SileoLog: updatePopup(\(completion),\(bypass)) : \(self.view.frame.width) : queueRunning=\(manager.queueRunning) aptRunning=\(manager.aptRunning)  aptFinished=\(manager.aptFinished) operationCount=\(manager.operationCount()) downloading=\(manager.downloadingPackages()) ready=\(manager.readyPackages()) installing=\(manager.installingPackages()) uninstalling=\(manager.uninstallingPackages()) verifyComplete=\(manager.verifyComplete())")
//        Thread.callStackSymbols.forEach{NSLog("SileoLog: updatePopup callstack=\($0)")}
        
        if manager.operationCount() == 0 {
            assert(manager.queueRunning == false)
            
            //requires async due the deadlock: dismissPopupController->(LNPopupController)->viewDidLayoutSubviews->updatePopup->dismissPopup on iphone mode on ipad
            DispatchQueue.main.async {
                hideRegardless()
            }
        }
        else if !manager.queueRunning {
            downloadsController?.popupItem.title = String(localizationKey: "Queued_Package_Status")
            downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.operationCount())
            downloadsController?.popupItem.progress = 0
            self.presentPopup(completion: completion)
        }
        else if manager.aptFinished {
            downloadsController?.popupItem.title = String(localizationKey: "Done")
            downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.operationCount())
            downloadsController?.popupItem.progress = 0
            self.presentPopup(completion: completion)
        }
        else if manager.aptRunning {
            if manager.installingPackages() > 0 {
                downloadsController?.popupItem.title = String(localizationKey: "Installing_Package_Status")
                downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.installingPackages())
                downloadsController?.popupItem.progress = 0
                self.presentPopup(completion: completion)
            } else if manager.uninstallingPackages() > 0 {
                downloadsController?.popupItem.title = String(localizationKey: "Removal_Queued_Package_Status")
                downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.uninstallingPackages())
                downloadsController?.popupItem.progress = 0
                self.presentPopup(completion: completion)
            }
        }
        else {
            if manager.downloadingPackages() > 0 {
                downloadsController?.popupItem.title = String(localizationKey: "Downloading_Package_Status")
                downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.downloadingPackages())
                downloadsController?.popupItem.progress = 0
                self.presentPopup(completion: completion)
            } else if manager.verifyComplete() {
                downloadsController?.popupItem.title = String(localizationKey: "Ready_Status")
                downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.operationCount())
                downloadsController?.popupItem.progress = 0
                self.presentPopup(completion: completion)
            }
        }
    }
    
    override var bottomDockingViewForPopupBar: UIView? {
        self.tabBar
    }
    
    override var defaultFrameForBottomDockingView: CGRect {
        NSLog("SileoLog: TabBarController.defaultFrameForBottomDockingView")
        var tabBarFrame = self.tabBar.frame
        tabBarFrame.origin.y = self.view.bounds.height - tabBarFrame.height
        if UIDevice.current.userInterfaceIdiom == .pad {
            tabBarFrame.origin.x = 0
            tabBarFrame.size.width = self.view.bounds.width
            if tabBarFrame.width >= ipadModeMinWidth {
                tabBarFrame.size.width -= 320
            }
        }
        return tabBarFrame
    }
    
    private var floatingInset: CGFloat { 10 }
    private var floatingPopupTabBarHeight: CGFloat {
        // Popup bottom edge should touch the capsule's top edge
        if isFloatingEnabled, let container = floatingBackground, !container.isHidden, container.frame.height > 0 {
            return max(self.tabBar.frame.height, self.tabBar.bounds.height - container.frame.minY)
        }
        return self.tabBar.frame.height
    }
    private var floatingRetryCount = 0
    private var floatingBackground: UIView?
    private var floatingAppearance: UITabBarAppearance?
    private var floatingItemWidth: CGFloat = 0
    private var floatingRefreshPending = false
    private var floatingSettled = false
    private var floatingTrusted = false
    private var floatingTrustedReselected = false
    private let floatingItemWidthKey = "FloatingTabBarCalibratedItemWidth"
    private let floatingBarWidthKey = "FloatingTabBarCalibratedBarWidth"
    private var floatingReferenceWidth: CGFloat {
        self.tabBar.bounds.width > 0 ? self.tabBar.bounds.width : self.view.bounds.width
    }

    private func revealFloatingTabBar(save: Bool = true) {
        floatingSettled = true
        if save, floatingItemWidth > 0 {
            UserDefaults.standard.set(Double(floatingItemWidth), forKey: floatingItemWidthKey)
            UserDefaults.standard.set(Double(floatingReferenceWidth), forKey: floatingBarWidthKey)
        }
        guard self.tabBar.alpha < 1 else { return }
        UIView.animate(withDuration: 0.2) { self.tabBar.alpha = 1 }
    }
    private var originalStandardAppearance: UITabBarAppearance?
    private var originalScrollEdgeAppearance: UITabBarAppearance?

    private var isFloatingEnabled: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && UserDefaults.standard.bool(forKey: "FloatingTabBar", fallback: false)
    }

    @objc private func floatingTabBarChanged() {
        if popupIsPresented {
            self.popupBar.tabBarHeight = floatingPopupTabBarHeight
        }
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
    }

    // Icon image view of a tab button, ignoring badge views (items with badges nest their views differently)
    private func iconImageView(in view: UIView) -> UIImageView? {
        var best: UIImageView?
        func walk(_ v: UIView) {
            for sub in v.subviews {
                if String(describing: type(of: sub)).contains("Badge") { continue }
                if let imageView = sub as? UIImageView, imageView.bounds.width > 12 {
                    if best == nil || imageView.bounds.width * imageView.bounds.height > best!.bounds.width * best!.bounds.height {
                        best = imageView
                    }
                }
                walk(sub)
            }
        }
        walk(view)
        return best
    }

    private func buttonsSortedByX() -> [UIView] {
        var result: [UIView] = []
        func walk(_ v: UIView) {
            for sub in v.subviews {
                if String(describing: type(of: sub)).contains("TabBarButton") { result.append(sub) } else { walk(sub) }
            }
        }
        walk(self.tabBar)
        return result.sorted { $0.frame.midX < $1.frame.midX }
    }

    private func animateSelectedIcon() {
        guard isFloatingEnabled else { return }
        let buttons = buttonsSortedByX()
        let index = self.selectedIndex
        guard index < buttons.count, let icon = iconImageView(in: buttons[index]) else { return }
        playIconAnimation(for: index, on: icon)
    }

    // Per-tab icon animations: featured, changes, sources, packages, search
    private func playIconAnimation(for index: Int, on icon: UIView) {
        let layer = icon.layer
        layer.removeAllAnimations()
        func keyframes(_ keyPath: String, _ values: [CGFloat], _ duration: CFTimeInterval) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = duration
            animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(values.count - 1, 1))
            layer.add(animation, forKey: keyPath)
        }
        switch index {
        case 0: // star: spin and pop
            keyframes("transform.rotation.z", [0, CGFloat.pi * 2], 0.6)
            keyframes("transform.scale", [1, 1.3, 1], 0.6)
        case 1: // changes: wiggle
            keyframes("transform.rotation.z", [0, -0.35, 0.3, -0.2, 0.1, 0], 0.55)
        case 2: // globe: roll around
            keyframes("transform.rotation.z", [0, CGFloat.pi * 2], 0.7)
        case 3: // packages: drop and bounce
            keyframes("transform.translation.y", [-14, 4, -5, 0], 0.55)
            keyframes("transform.scale", [0.85, 1.1, 1], 0.55)
        case 4: // search: sweep like looking around
            keyframes("transform.rotation.z", [0, -0.5, 0.5, -0.25, 0], 0.6)
            keyframes("transform.scale", [1, 1.2, 1], 0.6)
        default:
            keyframes("transform.scale", [1, 1.25, 1], 0.4)
        }
    }

    private func applyFloatingStyle() {
        guard isFloatingEnabled else {
            if let container = floatingBackground {
                container.removeFromSuperview()
                floatingBackground = nil
                floatingAppearance = nil
                floatingItemWidth = 0
                floatingRefreshPending = false
                floatingSettled = false
                floatingTrusted = false
                floatingTrustedReselected = false
                UserDefaults.standard.removeObject(forKey: floatingItemWidthKey)
                UserDefaults.standard.removeObject(forKey: floatingBarWidthKey)
                self.tabBar.alpha = 1
                self.tabBar._blurEnabled = true
                self.tabBar.standardAppearance = originalStandardAppearance ?? UITabBarAppearance()
                self.tabBar.scrollEdgeAppearance = originalScrollEdgeAppearance
                self.tabBar.itemWidth = 0
                self.tabBar.itemSpacing = 0
            }
            return
        }
        if floatingBackground == nil {
            originalStandardAppearance = self.tabBar.standardAppearance
            originalScrollEdgeAppearance = self.tabBar.scrollEdgeAppearance
            let appearance = UITabBarAppearance()
            appearance.configureWithTransparentBackground()
            self.tabBar.standardAppearance = appearance
            self.tabBar.scrollEdgeAppearance = appearance
            floatingAppearance = appearance
            var cached = CGFloat(UserDefaults.standard.double(forKey: floatingItemWidthKey))
            let cachedBarWidth = CGFloat(UserDefaults.standard.double(forKey: floatingBarWidthKey))
            // A calibration only holds for the bar width it was measured at
            if floatingReferenceWidth > 0, abs(cachedBarWidth - floatingReferenceWidth) > 1 { cached = 0 }
            if cached > 0 {
                floatingTrusted = true
                // Reuse the saved calibration so the bar appears in its final layout immediately
                floatingItemWidth = cached
                appearance.stackedItemPositioning = .centered
                appearance.stackedItemWidth = cached
                appearance.stackedItemSpacing = 0
                self.tabBar.standardAppearance = appearance
                self.tabBar.scrollEdgeAppearance = appearance
                floatingSettled = true
            } else {
                // Hide until item metrics have been corrected, to avoid a visible shrink
                floatingSettled = false
                self.tabBar.alpha = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    if let self = self, self.isFloatingEnabled { self.revealFloatingTabBar(save: false) }
                }
            }

            let container = UIView()
            container.isUserInteractionEnabled = false
            container.layer.shadowColor = UIColor.black.cgColor
            container.layer.shadowOpacity = 0.2
            container.layer.shadowRadius = 10
            container.layer.shadowOffset = CGSize(width: 0, height: 4)
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            blur.tag = 1
            blur.clipsToBounds = true
            blur.layer.cornerCurve = .continuous
            container.addSubview(blur)
            self.tabBar.insertSubview(container, at: 0)
            floatingBackground = container
        }
        guard let container = floatingBackground, let blur = container.viewWithTag(1) else { return }
        let barHeight: CGFloat = 78
        // Center the capsule on the visible icon+label row so top/bottom spacing is equal
        var rowMids: [CGFloat] = []
        var colMids: [CGFloat] = []
        func collect(_ view: UIView) {
            for sub in view.subviews {
                if String(describing: type(of: sub)).contains("TabBarButton") {
                    let content = sub.subviews.filter { $0 is UIImageView || $0 is UILabel || String(describing: type(of: $0)).contains("ImageView") }
                    let union = content.reduce(CGRect.null) { $0.union($1.frame) }
                    let rect = union.isNull ? sub.bounds : union
                    rowMids.append(self.tabBar.convert(rect, from: sub).midY)
                    colMids.append(self.tabBar.convert(sub.bounds, from: sub).midX)
                } else {
                    collect(sub)
                }
            }
        }
        collect(self.tabBar)
        guard !rowMids.isEmpty else {
            // Buttons are not laid out yet (cold launch); hide the capsule and retry shortly
            container.isHidden = true
            if floatingRetryCount < 20 {
                floatingRetryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.applyFloatingStyle() }
            }
            return
        }
        floatingRetryCount = 0
        container.isHidden = false
        let itemMidY = rowMids.reduce(0, +) / CGFloat(rowMids.count)
        let frame = CGRect(x: floatingInset, y: itemMidY - barHeight / 2, width: self.tabBar.bounds.width - floatingInset * 2, height: barHeight)
        container.frame = frame
        if popupIsPresented, self.popupBar.tabBarHeight != floatingPopupTabBarHeight {
            self.popupBar.tabBarHeight = floatingPopupTabBarHeight
        }
        blur.frame = container.bounds
        blur.layer.cornerRadius = barHeight / 2
        container.layer.shadowPath = UIBezierPath(roundedRect: container.bounds, cornerRadius: barHeight / 2).cgPath
        self.tabBar.sendSubviewToBack(container)

        // The system adds its own padding between items, so measure the real pitch
        // and correct itemWidth until five items evenly fill the capsule with a small side margin
        let count = CGFloat(max(self.tabBar.items?.count ?? 1, 1))
        let spacing: CGFloat = 0
        let sideMargin: CGFloat = 20
        let targetPitch = (frame.width - sideMargin * 2) / count
        // Skip correction while a previous change has not been laid out yet, otherwise it would overshoot
        guard !floatingRefreshPending else { return }
        var itemWidth = floatingItemWidth > 0 ? floatingItemWidth : targetPitch.rounded(.down)
        let sortedMids = colMids.sorted()
        if sortedMids.count >= 2, let first = sortedMids.first, let last = sortedMids.last {
            let actualPitch = (last - first) / CGFloat(sortedMids.count - 1)
            if abs(actualPitch - targetPitch) <= 1 {
                floatingTrusted = false
                revealFloatingTabBar()
            } else if floatingTrusted && !floatingTrustedReselected {
                // The saved width is right; the system just has not re-read it yet, so only relayout once
                floatingTrustedReselected = true
                reselectToRefreshItemMetrics()
                return
            } else {
                floatingTrusted = false
                itemWidth = max(20, (itemWidth + targetPitch - actualPitch).rounded(.down))
            }
        }
        // On iOS 13+ the legacy itemWidth/itemSpacing/itemPositioning are overridden by the
        // appearance's stacked* values, so they must be set on the appearance itself
        if let appearance = floatingAppearance, floatingItemWidth != itemWidth || appearance.stackedItemPositioning != .centered {
            floatingItemWidth = itemWidth
            appearance.stackedItemPositioning = .centered
            appearance.stackedItemWidth = itemWidth
            appearance.stackedItemSpacing = spacing
            self.tabBar.standardAppearance = appearance
            self.tabBar.scrollEdgeAppearance = appearance
            // UITabBar only re-reads stacked item metrics on a selection change, so re-select the current tab (tabBar.selectedItem must not be touched directly)
            reselectToRefreshItemMetrics()
        }
    }

    private func reselectToRefreshItemMetrics() {
        floatingRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.selectedIndex = self.selectedIndex
            self.tabBar.setNeedsLayout()
            self.tabBar.layoutIfNeeded()
            self.floatingRefreshPending = false
            self.tabBar.setNeedsLayout()
        }
    }

    override var insetsForBottomDockingView: UIEdgeInsets {
        if UIDevice.current.userInterfaceIdiom == .pad {
            if self.view.bounds.width < ipadModeMinWidth {
                return .zero
            }
            return UIEdgeInsets(top: self.tabBar.frame.height, left: self.view.bounds.width - 320, bottom: 0, right: 0)
        }
        return .zero
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        updateSileoColors()
    }
    
    @objc func updateSileoColors() {
        if UIColor.isDarkModeEnabled {
            self.popupBar.systemBarStyle = .black
            self.popupBar.toolbar.barStyle = .black
        } else {
            self.popupBar.systemBarStyle = .default
            self.popupBar.toolbar.barStyle = .default
        }
    }
    
    override func viewDidLayoutSubviews() {
        NSLog("SileoLog: TabBarController.viewDidLayoutSubviews")
        super.viewDidLayoutSubviews()
        
        self.tabBar.itemPositioning = .centered
        applyFloatingStyle()
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.updatePopup(animated: false)
        }
    }
    
    public func displayError(_ string: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.displayError(string)
            }
            return
        }
        let alertController = UIAlertController(title: String(localizationKey: "Unknown", type: .error), message: string, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .default))
        self.present(alertController, animated: true, completion: nil)
    }
}

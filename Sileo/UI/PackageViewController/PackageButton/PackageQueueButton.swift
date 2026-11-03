//
//  PackageQueueButton.swift
//  Sileo
//
//  Created by CoolStar on 4/20/20.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation

protocol PackageQueueButtonDataProvider: AnyObject {
    
}

class PackageQueueButton: PackageButton {
    private var contextMenuDelegate: AnyObject?
    weak var versionSelectionNavigationController: UINavigationController?
    
    static let actionPerformedNotification = Notification.Name("actionPerformedNotification")

    public weak var viewControllerForPresentation: UIViewController?
    public var package: Package? {
        didSet {
            DispatchQueue.main.async {
                if let package=self.package, package.commercial {
                    self.paymentInfo = PaymentPackageInfo(price: String(localizationKey: "Package_Paid"), purchased: false, available: true)
                    //paymentInfo->didSet->self.updateInfo()
                } else {
                    self.updateInfo()
                }
            }
        }
    }

    public var paymentInfo: PaymentPackageInfo? {
        didSet {
            DispatchQueue.main.async {
                self.updateInfo()
            }
        }
    }
    
    public var overrideTitle: String = ""
    
    private var installedPackage: Package?
    
    override func setup() {
        super.setup()
        
        self.updateButton(title: String(localizationKey: "Package_Get_Action"))
        self.addTarget(self, action: #selector(PackageQueueButton.buttonTapped(_:)), for: .touchUpInside)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(PackageQueueButton.updateInfo),
                                               name: PackageListManager.stateChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(PackageQueueButton.updateInfo),
                                               name: DownloadManager.lockStateChangeNotification,
                                               object: nil)
        
        if #available(iOS 14.0, *) {
            // UIButton.menu shows a plain popup on long press, without the blurred context-menu backdrop
            menu = UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let self = self, let package = self.package, !(package.isProvisional ?? false) else {
                        completion([])
                        return
                    }
                    completion(self.longPressMenuItems(for: package).map { item in
                        UIAction(title: item.title, image: UIImage(systemName: item.image), attributes: item.enabled ? (item.destructive ? .destructive : []) : .disabled) { _ in item.handler() }
                    })
                }
            ])
        } else if #available(iOS 13.0, *) {
            let menuDelegate = PackageQueueMenuDelegate(button: self)
            contextMenuDelegate = menuDelegate
            addInteraction(UIContextMenuInteraction(delegate: menuDelegate))
        } else {
            let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(PackageQueueButton.longPressed(_:)))
            addGestureRecognizer(longPressGesture)
        }
    }

    @objc func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        showLongPressMenu()
    }

    private func presentSheet(_ sheet: UIAlertController) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            sheet.popoverPresentationController?.sourceView = self
            sheet.popoverPresentationController?.sourceRect = self.bounds
        }
        let tintColor = self.tintColor
        sheet.view.tintColor = tintColor
        viewControllerForPresentation?.present(sheet, animated: true, completion: {
            sheet.view.tintColor = tintColor
        })
    }

    private func showLongPressMenu() {
        guard let package = package, !(package.isProvisional ?? false) else {
            return
        }
        let menu = UIAlertController(title: package.name, message: nil, preferredStyle: .alert)
        for item in longPressMenuItems(for: package) {
            let action = UIAlertAction(title: item.title, style: item.destructive ? .destructive : .default) { _ in item.handler() }
            action.isEnabled = item.enabled
            menu.addAction(action)
        }
        menu.addAction(UIAlertAction(title: String(localizationKey: "Package_Cancel_Action"), style: .cancel, handler: nil))
        let tintColor = self.tintColor
        menu.view.tintColor = tintColor
        viewControllerForPresentation?.present(menu, animated: true, completion: {
            menu.view.tintColor = tintColor
        })
    }

    fileprivate typealias MenuItem = (title: String, image: String, destructive: Bool, enabled: Bool, handler: () -> Void)

    // Primary actions (install / update / reinstall / downgrade, uninstall) come first and follow the page's selected version
    fileprivate func longPressMenuItems(for package: Package) -> [MenuItem] {
        var items: [MenuItem] = []
        // a paid package that has not been bought yet can only be acted on once the price button turns into install
        let unlocked = !awaitingPayment(for: package)

        if let installed = PackageListManager.shared.installedPackage(identifier: package.package) {
            var target: Package?
            var title = String(localizationKey: "Package_Reinstall_Action")
            var image = "arrow.clockwise.circle"
            var queue = DownloadManagerQueue.installations
            var ambiguous = false
            if package.fromStatusFile,
               let update = PackageListManager.shared.updateCandidate(for: installed),
               checkRootHide(update),
               DpkgWrapper.isVersion(update.version, greaterThan: installed.version) {
                target = update
                title = String(localizationKey: "Package_Upgrade_Action")
                image = "icloud.and.arrow.down"
                queue = .upgrades
            } else if package.fromStatusFile || package.version == installed.version {
                let resolved = resolveDownloadable(for: package)
                target = resolved.package
                ambiguous = resolved.ambiguous
            } else if DpkgWrapper.isVersion(package.version, greaterThan: installed.version) {
                target = package
                title = String(localizationKey: "Package_Upgrade_Action")
                image = "icloud.and.arrow.down"
                queue = .upgrades
            } else {
                target = package
                title = String(localizationKey: "Package_Downgrade_Action")
                image = "arrow.down.circle"
            }
            if let target = target {
                items.append((title, image, false, true, {
                    self.hapticResponse()
                    if ambiguous {
                        // several sources match equally; let the user pick which one to reinstall from
                        self.useVisiblePresenter()
                        self.showVersionPrompt(nil)
                    } else {
                        self.requestQueuePackage(package: target, queue: queue)
                    }
                }))
            }
            items.append((String(localizationKey: "Package_Uninstall_Action"), "trash.circle", true, true, {
                self.hapticResponse()
                self.requestQueuePackage(package: package, queue: .uninstallations)
            }))
        } else if !package.fromStatusFile && (package.sourceRepo != nil || package.local_deb != nil) {
            items.append((String(localizationKey: "Package_Get_Action"), "square.and.arrow.down", false, unlocked, {
                self.hapticResponse()
                self.requestQueuePackage(package: package, queue: .installations)
            }))
        }

        items.append((String(localizationKey: "Package_Choose_Version"), "list.bullet", false, unlocked, { self.showVersionPrompt(nil) }))

        let holdTarget = PackageListManager.shared.installedPackage(identifier: package.package)
        let holding = holdTarget?.wantInfo == .hold || (holdTarget == nil && DpkgWrapper.isIgnoringUpdates(package: package.package))
        let holdTitle = String(localizationKey: holding ? "Package_Hold_Disable_Action" : "Package_Hold_Enable_Action")
        items.append((holdTitle, holding ? "hand.raised.slash" : "hand.raised", false, true, { self.setIgnoreUpdates(!holding, package: holdTarget ?? package) }))

        if let downloadable = downloadablePackage(for: package) {
            items.append((String(localizationKey: "Package_Download_Deb"), "arrow.down.to.line", false, unlocked, { self.downloadDeb(downloadable) }))
        }
        items.append((String(localizationKey: "Package_View_Info"), "doc.text", false, true, { self.showPackageInfo(package) }))
        return items
    }

    // Installed (dpkg status) entries have no filename/repo, so resolve the same version from the sources.
    // `ambiguous` means several sources fit equally well and the user should choose.
    private func resolveDownloadable(for package: Package) -> (package: Package?, ambiguous: Bool) {
        if package.local_deb != nil || (package.filename != nil && package.sourceRepo != nil) {
            return (package, false)
        }
        return PackageListManager.shared.installedOrigin(of: package)
    }

    private func downloadablePackage(for package: Package) -> Package? {
        resolveDownloadable(for: package).package
    }

    private func setIgnoreUpdates(_ ignore: Bool, package installed: Package) {
        #if !targetEnvironment(simulator) && !TARGET_SIMULATOR
        do {
            try DpkgWrapper.ignoreUpdates(ignore, package: installed.package)
            installed.wantInfo = ignore ? .hold : .install
        } catch {
            let alert = UIAlertController(title: String(localizationKey: "Unknown", type: .error), message: "\(error)", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .cancel, handler: nil))
            viewControllerForPresentation?.present(alert, animated: true, completion: nil)
            return
        }
        #endif
        NotificationCenter.default.post(Notification(name: PackageListManager.prefsNotification))
    }

    private func downloadDeb(_ package: Package) {
        DownloadManager.shared.downloadDeb(package: package, msg: String(localizationKey: "Package_Downloading"), showsProgress: true) { package, fileURL in
            let name = "\(package.package)_\(package.version)_\(package.architecture ?? "unknown").deb"
            let shared = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: shared)
            do {
                try FileManager.default.copyItem(at: fileURL, to: shared)
            } catch {
                let alert = UIAlertController(title: String(localizationKey: "Unknown", type: .error), message: "\(error)", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .cancel, handler: nil))
                self.viewControllerForPresentation?.present(alert, animated: true, completion: nil)
                return
            }
            let activity = UIActivityViewController(activityItems: [shared], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: shared) }
            activity.popoverPresentationController?.sourceView = self
            activity.popoverPresentationController?.sourceRect = self.bounds
            self.viewControllerForPresentation?.present(activity, animated: true, completion: nil)
        }
    }

    // Context-menu previews are not in the view hierarchy, so present from what is actually on screen
    private func useVisiblePresenter() {
        guard viewControllerForPresentation?.view.window == nil else { return }
        var top = UIApplication.shared.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        viewControllerForPresentation = top
    }

    private static func navigationController(containing controller: UIViewController) -> UINavigationController? {
        var current: UIViewController? = controller
        while let vc = current {
            if let nav = vc as? UINavigationController { return nav }
            if let nav = vc.navigationController { return nav }
            if let tab = vc as? UITabBarController { current = tab.selectedViewController; continue }
            if let split = vc as? UISplitViewController { current = split.viewControllers.last; continue }
            return nil
        }
        return nil
    }

    private func showPackageInfo(_ package: Package) {
        let controller = PackageControlInfoViewController(package: package)
        let navigation = UINavigationController(rootViewController: controller)
        viewControllerForPresentation?.present(navigation, animated: true, completion: nil)
    }

    @objc func showVersionPrompt(_ sender: Any?) {
        guard let package = package, !(package.isProvisional ?? false) else {
            return
        }
        var repos = RepoManager.shared.repoList
        if let sourceRepo = package.sourceRepo, !repos.contains(sourceRepo) {
            repos.append(sourceRepo)
        }
        var sections: [(title: String, packages: [Package])] = []
        for repo in repos {
            let versions = repo.allVersions(identifier: package.package, ignoreArch: true)
            if versions.isEmpty { continue }
            let sorted = versions.sorted { (first: Package, second: Package) -> Bool in
                DpkgWrapper.isVersion(first.version, greaterThan: second.version)
            }
            sections.append((title: repo.displayName, packages: sorted))
        }
        sections.sort { (first, second) -> Bool in
            first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending
        }

        guard !sections.isEmpty else { return }
        // capture strongly: the long-press preview (and this button) may be released before a version is picked
        let listNavigationController = self.versionSelectionNavigationController
        let presenter = self.viewControllerForPresentation
        let picker = PackageVersionPickerController(sections: sections, current: package) { selected in
            guard let viewController = presenter else { return }
            if let navigationController = listNavigationController {
                navigationController.pushViewController(
                    NativePackageViewController.viewController(for: selected),
                    animated: true
                )
            } else if let packageViewController = viewController as? PackageViewController, packageViewController.view.window != nil {
                packageViewController.show(package: selected)
            } else if let navigationController = PackageQueueButton.navigationController(containing: viewController) {
                navigationController.pushViewController(
                    NativePackageViewController.viewController(for: selected),
                    animated: true
                )
            } else {
                viewController.present(
                    UINavigationController(rootViewController: NativePackageViewController.viewController(for: selected)),
                    animated: true
                )
            }
        }
        let navigationController = UINavigationController(rootViewController: picker)
        navigationController.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *), let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        viewControllerForPresentation?.present(navigationController, animated: true)
    }
    
    func checkQueued(package: Package) -> Bool
    {
        let queueFound = DownloadManager.shared.find(package: package)
        
        if queueFound == .none {
            return false
        }
        
        if package.fromStatusFile {
            if queueFound == .installdeps || queueFound == .uninstalldeps {
                return true
            } else {
                return false
            }
        }
        
        let queuedDownloadPackage = DownloadManager.shared.findDownloadPackage(package: package)
        if let queuedPackage = queuedDownloadPackage?.package {
            if package.fromStatusFile != queuedPackage.fromStatusFile {
                return false
            }
            else if package.version != queuedPackage.version {
                return false
            }
            else if package.local_deb != queuedPackage.local_deb {
                return false
            }
            else if package.sourceRepo != queuedPackage.sourceRepo {
                return false
            }
        }
        
        return true
    }
    
    @objc func updateInfo() {
        var primaryMenu = false
        defer {
            if #available(iOS 14.0, *) {
                self.showsMenuAsPrimaryAction = primaryMenu
            }
        }
//        NSLog("SileoLog: updateInfo package=\(package?.package)")
        guard let package = package else {
            self.updateButton(title: String(localizationKey: "Package_Get_Action"))
            self.isEnabled = false
            return
        }

        if package.isProvisional ?? false {
            self.updateButton(title: String(localizationKey: "Add_Source.Title"))
            return
        } else if !package.fromStatusFile && package.sourceRepo==nil && package.local_deb==nil {
            self.updateButton(title: String(localizationKey: "Package_Get_Action"))
            self.isEnabled = false
            return
        }
        
        installedPackage = PackageListManager.shared.installedPackage(identifier: package.package)
        let purchased = paymentInfo?.purchased ?? false
        
        //Competition with DependencyResolverAccelerator.shared.preflightInstalled()->init(){4 spawns} for aptQueue causes a two second lag
        
        if !overrideTitle.isEmpty {
            self.updateButton(title: overrideTitle)
        } else if checkQueued(package: package) {
            self.updateButton(title: String(localizationKey: "Package_Queue_Action"))
        } else if installedPackage != nil {
            self.updateButton(title: String(localizationKey: "Package_Modify_Action"))
            if #available(iOS 14.0, *) {
                // a tap on an installed package opens the same popup menu as a long press
                primaryMenu = true
            }
        } else if let price = paymentInfo?.price, package.commercial && !purchased {
            self.updateButton(title: price)
        } else {
            self.updateButton(title: String(localizationKey: "Package_Get_Action"))
            self.isProminent = true
        }
        
        self.isEnabled = !DownloadManager.shared.queueRunning
    }
    
    func updateButton(title: String) {
        self.setTitle(title.uppercased(), for: .normal)
    }
    
    func actionItems() -> [CSActionItem] {
        guard let package = self.package else {
                return []
        }
        if package.isProvisional ?? false {
            guard let source = package.source else {
                return []
            }
            let action = CSActionItem(title: String(localizationKey: "Add_Source.Title"),
                                      image: UIImage(systemNameOrNil: "square.and.arrow.down"),
                                      style: .default) {
                self.hapticResponse()
                self.addRepo(source)
                CanisterResolver.shared.queuePackage(package)
            }
            return [action]
        }
        var actionItems: [CSActionItem] = []

        if DownloadManager.shared.queueRunning { return [] }

        for item in longPressMenuItems(for: package) {
            actionItems.append(CSActionItem(title: item.title, image: UIImage(systemNameOrNil: item.image), style: item.destructive ? .destructive : .default) {
                self.useVisiblePresenter()
                item.handler()
            })
        }
    
        let copyBundleIDAction = CSActionItem(title: String(localizationKey: "Copy_ID"), image: .init(systemNameOrNil: "doc.on.doc"), style: .default) {
            UIPasteboard.general.string = package.package
        }
        actionItems.append(copyBundleIDAction)
        
        return actionItems
    }
    
    private func addRepo(_ source: ProvisionalRepo) {
        // sometimes self.window may be nil if QueueButton os not being shown
        //if let tabBarController = self.window?.rootViewController as? UITabBarController,
        if let tabBarController = TabBarController.singleton,
            let sourcesSVC = tabBarController.viewControllers?[2] as? UISplitViewController,
              let sourcesNavNV = sourcesSVC.viewControllers[0] as? SileoNavigationController {
              tabBarController.selectedViewController = sourcesSVC
              if let sourcesVC = sourcesNavNV.viewControllers[0] as? SourcesViewController {
                  if source.suite == "./" {
                      sourcesVC.presentAddSourceEntryField(url: source.uri)
                  } else {
                      sourcesVC.addDistRepo(string: source.uri.absoluteString, suites: source.suite, components: source.component)
                  }
              }
        }
    }
    
    private func handleButtonPress(_ package: Package, _ check: Bool = true) {
        if check {
            if package.isProvisional ?? false {
                guard let source = package.source else { return }
                self.addRepo(source)
                CanisterResolver.shared.queuePackage(package)
                return
            }
        }
        if DownloadManager.shared.queueRunning {
            TabBarController.singleton?.presentPopupController()
            return
        }
        self.hapticResponse()
        
        let downloadManager = DownloadManager.shared
        
        if(checkQueued(package: package)) {
            // but it's a already queued! user changed their mind about installing this new package => nuke it from the queue
            TabBarController.singleton?.presentPopupController()
            downloadManager.reloadData(recheckPackages: true)
            
            NotificationCenter.default.post(name: PackageQueueButton.actionPerformedNotification, object: nil)
                
        } else if installedPackage != nil {
            NSLog("SileoLog: \(package.package) commercial=\(package.commercial) purchased=\(paymentInfo?.purchased) price=\(paymentInfo?.price) available=\(paymentInfo?.available)")
            // road clear to modify an installed package: show the same menu as long press
            self.showLongPressMenu()
        } else if package.sourceRepo != nil || package.local_deb != nil {
            self.requestQueuePackage(package: package, queue: .installations)
        } else {
            self.showVersionPrompt(nil)
        }
    }
    
    @objc func buttonTapped(_ sender: Any?) {
        guard let package = self.package else {
            return
        }
        self.handleButtonPress(package)
    }
    
    private func queuePackage(_ package: Package, _ queue: DownloadManagerQueue)
    {
        if DownloadManager.shared.queueRunning { return }
        DownloadManager.shared.add(package: package, queue: queue) {
            DownloadManager.shared.reloadData(recheckPackages: true)
        }
        NotificationCenter.default.post(name: PackageQueueButton.actionPerformedNotification, object: nil)
    }
    
    // the state in which the button shows the price instead of install
    private func awaitingPayment(for package: Package) -> Bool {
        guard PackageListManager.shared.installedPackage(identifier: package.package) == nil else { return false }
        return paymentInfo?.price != nil && package.commercial && !(paymentInfo?.purchased ?? false)
    }
    
    private var hasPurchased: Bool {
        guard let paymentInfo=self.paymentInfo else {
            return false
        }
        return paymentInfo.purchased && paymentInfo.available
    }
    
    private func requestQueuePackage(package: Package, queue: DownloadManagerQueue)
    {
        NSLog("SileoLog: requestQueuePackage \(package.package)=\(package.version) commercial=\(package.commercial) \(package.sourceRepo):\(package.sourceRepo?.rawURL) purchased=\(self.hasPurchased) queue=\(queue.rawValue)")
        
        if DownloadManager.shared.queueRunning { return }
        
        //some repos(eg:Chariz) only set the latest packages as cydia::commercial
        guard let mainPackage = self.package else {
            return
        }
        
        //local deb?
        guard let repo = package.sourceRepo, mainPackage.commercial, !self.hasPurchased, queue != .uninstallations else {
            return queuePackage(package, queue)
        }
        
        PaymentManager.shared.getPaymentProvider(for: repo) { error, provider in
            if let error = error {
                self.presentAlert(paymentError: error, title: String(localizationKey: "Purchase_Auth_Complete_Fail.Title", type: .error))
                return
            }
            guard let provider = provider else {
                self.presentAlert(paymentError: .noPaymentProvider, title: String(localizationKey: "Purchase_Auth_Complete_Fail.Title", type: .error))
                return
            }

            if !provider.isAuthenticated {
                return self.authenticate(provider: provider, package: package, completion: {
                    self.requestQueuePackage(package: package, queue: queue)
                })
            }
            
            self.updatePurchaseStatus(provider, package) { purchased in
                if purchased {
                    NSLog("SileoLog: updatePurchaseStatus add(package=\(package))")
                    self.queuePackage(package, queue)
                } else {
                    self.initatePurchase(provider: provider, package: package, queue: queue)
                }
            }
        }
    }
    
    private func updatePurchaseStatus(_ provider: PaymentProvider, _ package: Package, _ completion: ((Bool) -> Void)?) {
        provider.getPackageInfo(forIdentifier: package.package) { error, info in
            if let error = error {
                return self.presentAlert(paymentError: error, title: String(localizationKey: "Purchase_Auth_Complete_Fail.Title", type: .error))
            }
            guard let info = info else {
                return self.presentAlert(paymentError: .invalidResponse, title: String(localizationKey: "Purchase_Auth_Complete_Fail.Title", type: .error))
            }
            if !info.available {
                return self.presentAlert(paymentError: PaymentError(message: String(localizationKey: "Package_Unavailable")),
                                  title: String(localizationKey: "Purchase_Auth_Complete_Fail.Title", type: .error))
            }
            
            self.paymentInfo = info
            
            completion?(info.purchased)
            return
        }
    }
    
    private func initatePurchase(provider: PaymentProvider, package: Package, queue: DownloadManagerQueue) {
        provider.initiatePurchase(forPackageIdentifier: package.package) { error, status, actionURL in
            if let error = error {
                if error.shouldInvalidate {
                    self.authenticate(provider: provider, package: package, completion: {
                        self.requestQueuePackage(package: package, queue: queue)
                    })
                    return
                }
                return self.presentAlert(paymentError: error, title: String(localizationKey: "Purchase_Initiate_Fail.Title", type: .error))
            }
            if status == .immediateSuccess {
                //it's necessary to check the purchase status again?
                //return return self.requestQueuePackage(package: package, queue: queue)
                
                self.updatePurchaseStatus(provider, package, nil) //update button info
                return self.queuePackage(package, queue)
            }
            else if status == .actionRequired {
                DispatchQueue.main.async {
                    PaymentAuthenticator.shared.handlePayment(actionURL: actionURL!, provider: provider, window: self.window) { error, success in
                        if let error = error {
                            let title = String(localizationKey: "Purchase_Complete_Fail.Title", type: .error)
                            return self.presentAlert(paymentError: error, title: title)
                        }
                        if success {
                            //it's necessary to check the purchase status again?
                            //return return self.requestQueuePackage(package: package, queue: queue)
                            
                            self.updatePurchaseStatus(provider, package, nil) //update button info
                            return self.queuePackage(package, queue)
                        }
                    }
                }
            }
        }
    }
    
    private func authenticate(provider: PaymentProvider, package: Package, completion:@escaping ()->Void) {
        DispatchQueue.main.async {
            PaymentAuthenticator.shared.authenticate(provider: provider, window: self.window) { error, success in
                if let error = error {
                    return self.presentAlert(paymentError: error, title: String(localizationKey: "Purchase_Auth_Complete_Fail.Title", type: .error))
                }
                if success {
                    return completion()
                }
            }
        }
    }
    
    private func presentAlert(paymentError: PaymentError?, title: String) {
        SileoAppDelegate.presentController(PaymentError.alert(for: paymentError, title: title))
    }
    
    private func hapticResponse() {
        if #available(iOS 13, *) {
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.impactOccurred()
        } else {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
    }
}

@available(iOS 13.0, *)
private final class PackageQueueMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    private weak var button: PackageQueueButton?

    init(button: PackageQueueButton) {
        self.button = button
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let button = button, let package = button.package, !(package.isProvisional ?? false) else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak button] _ in
            guard let button = button else { return nil }
            let actions = button.longPressMenuItems(for: package).map { item in
                UIAction(title: item.title, image: UIImage(systemName: item.image), attributes: item.enabled ? [] : .disabled) { _ in
                    item.handler()
                }
            }
            return UIMenu(title: package.name, children: actions)
        }
    }
}

private final class PackageVersionPickerController: UITableViewController {
    private let sections: [(title: String, packages: [Package])]
    private let current: Package
    private let onPick: (Package) -> Void

    init(sections: [(title: String, packages: [Package])], current: Package, onPick: @escaping (Package) -> Void) {
        self.sections = sections
        self.current = current
        self.onPick = onPick
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localizationKey: "Package_Select_Version")
        tableView.backgroundColor = .sileoBackgroundColor
        tableView.separatorColor = .sileoSeparatorColor
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Version")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localizationKey: "Package_Cancel_Action"),
            style: .plain,
            target: self,
            action: #selector(cancel)
        )
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].packages.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Version", for: indexPath)
        let package = sections[indexPath.section].packages[indexPath.row]
        cell.textLabel?.text = package.version
        cell.accessoryType = isCurrent(package) ? .checkmark : .none
        cell.backgroundColor = .clear
        return cell
    }

    // The checkmark follows the version the page currently shows; an installed-list page has no repo, so it matches by version only
    private func isCurrent(_ package: Package) -> Bool {
        guard package.version == current.version else { return false }
        return current.sourceRepo == nil || package.sourceRepo == current.sourceRepo
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let package = sections[indexPath.section].packages[indexPath.row]
        dismiss(animated: true) { [weak self] in
            self?.onPick(package)
        }
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }
}


private final class PackageControlInfoViewController: UIViewController {
    private let package: Package
    private let textView = UITextView()

    init(package: Package) {
        self.package = package
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localizationKey: "Package_View_Info")
        view.backgroundColor = .sileoBackgroundColor
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))

        textView.isEditable = false
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        var text = ""
        if let data = package.rawData, let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            text = raw
        } else {
            text = package.rawControl.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        if let repo = package.sourceRepo {
            text += "\n\nRepository: \(repo.displayName)"
        }
        if let local = package.local_deb {
            text += "\n\nFile: \(local)"
        }
        textView.text = text
    }

    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }
}

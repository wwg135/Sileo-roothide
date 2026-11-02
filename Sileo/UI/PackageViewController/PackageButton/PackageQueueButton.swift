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
        
        if #available(iOS 13.0, *) {
            addInteraction(UIContextMenuInteraction(delegate: self))
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
            menu.addAction(UIAlertAction(title: item.title, style: .default) { _ in item.handler() })
        }
        menu.addAction(UIAlertAction(title: String(localizationKey: "Package_Cancel_Action"), style: .cancel, handler: nil))
        let tintColor = self.tintColor
        menu.view.tintColor = tintColor
        viewControllerForPresentation?.present(menu, animated: true, completion: {
            menu.view.tintColor = tintColor
        })
    }

    private func longPressMenuItems(for package: Package) -> [(title: String, image: String, handler: () -> Void)] {
        var items: [(title: String, image: String, handler: () -> Void)] = [
            (String(localizationKey: "Package_Choose_Version"), "list.bullet", { self.showVersionPrompt(nil) })
        ]

        if let installed = PackageListManager.shared.installedPackage(identifier: package.package) {
            let holding = installed.wantInfo == .hold
            let title = String(localizationKey: holding ? "Package_Hold_Disable_Action" : "Package_Hold_Enable_Action")
            items.append((title, holding ? "hand.raised.slash" : "hand.raised", { self.setIgnoreUpdates(!holding, installed: installed) }))
        }

        if package.local_deb != nil || (package.filename != nil && package.sourceRepo != nil) {
            items.append((String(localizationKey: "Package_Download_Deb"), "arrow.down.to.line", { self.downloadDeb(package) }))
        }
        items.append((String(localizationKey: "Package_View_Info"), "doc.text", { self.showPackageInfo(package) }))
        return items
    }

    private func setIgnoreUpdates(_ ignore: Bool, installed: Package) {
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
        DownloadManager.shared.downloadDeb(package: package, msg: String(localizationKey: "Loading")) { package, fileURL in
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
        let sections = repos
            .map { repo in
                (
                    title: repo.displayName,
                    packages: repo.allVersions(identifier: package.package, ignoreArch: true)
                        .sorted { DpkgWrapper.isVersion($0.version, greaterThan: $1.version) }
                )
            }
            .filter { !$0.packages.isEmpty }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        guard !sections.isEmpty else { return }
        let picker = PackageVersionPickerController(sections: sections) { [weak self] selected in
            self?.requestQueuePackage(package: selected, queue: .installations)
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

        let downloadManager = DownloadManager.shared
        
        if downloadManager.queueRunning { return [] }

        //self.installedPackage may not be ready yet
        if let installedPackage = PackageListManager.shared.installedPackage(identifier: package.package) {
            if !package.commercial || (paymentInfo?.available ?? false) {
                var repo: Repo?
                for repoEntry in RepoManager.shared.repoList where
                    repoEntry.rawEntry == package.sourceFile {
                    repo = repoEntry
                }
                if package.filename != nil && repo != nil {
                    if DpkgWrapper.isVersion(package.version, greaterThan: installedPackage.version) {
                        let action = CSActionItem(title: String(localizationKey: "Package_Upgrade_Action"),
                                                  image: UIImage(systemNameOrNil: "icloud.and.arrow.down"),
                                                  style: .default) {
                            self.hapticResponse()
                            self.requestQueuePackage(package: package, queue: .upgrades)
                        }
                        actionItems.append(action)
                    } else if package.version == installedPackage.version {
                        let action = CSActionItem(title: String(localizationKey: "Package_Reinstall_Action"),
                                                  image: UIImage(systemNameOrNil: "arrow.clockwise.circle"),
                                                  style: .default) {
                            self.hapticResponse()
                            self.requestQueuePackage(package: package, queue: .installations)
                        }
                        actionItems.append(action)
                    }
                }
            }
            let action = CSActionItem(title: String(localizationKey: "Package_Uninstall_Action"),
                                      image: UIImage(systemNameOrNil: "trash.circle"),
                                      style: .destructive) {
                self.hapticResponse()
                self.requestQueuePackage(package: package, queue: .uninstallations)
            }
            actionItems.append(action)
        } else if !package.fromStatusFile {
            let action = CSActionItem(title: String(localizationKey: "Package_Get_Action"),
                                      image: UIImage(systemNameOrNil: "square.and.arrow.down"),
                                      style: .default) {
                
                NSLog("SileoLog: Package_Get_Action0 \(package.package) \(package.sourceRepo) \(package.commercial) \(self.paymentInfo?.purchased)")
                self.hapticResponse()
                self.requestQueuePackage(package: package, queue: .installations)
            }
            actionItems.append(action)
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
                
        } else if let installedPackage = installedPackage {
            NSLog("SileoLog: \(package.package) commercial=\(package.commercial) purchased=\(paymentInfo?.purchased) price=\(paymentInfo?.price) available=\(paymentInfo?.available)")
            // road clear to modify an installed package, now we gotta decide what modification
            let downloadPopup: UIAlertController! = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
//            if !package.commercial || (paymentInfo?.available ?? false) {
                var repo: Repo?
                for repoEntry in RepoManager.shared.repoList where
                    repoEntry.rawEntry == package.sourceFile {
                    repo = repoEntry
                 }
                if !package.fromStatusFile {
                    if DpkgWrapper.isVersion(package.version, greaterThan: installedPackage.version) {
                        let upgradeAction = UIAlertAction(title: String(localizationKey: "Package_Upgrade_Action"), style: .default) { _ in
                            self.requestQueuePackage(package: package, queue: .upgrades)
                        }
                        downloadPopup.addAction(upgradeAction)
                    } else {
                        let reinstallAction = UIAlertAction(title: String(localizationKey: "Package_Reinstall_Action"), style: .default) { _ in
                            if package.version == installedPackage.version {
                                self.requestQueuePackage(package: package, queue: .installations)
                            } else {
                                downloadPopup.dismiss(animated: false) {
                                    self.showVersionPrompt(nil)
                                }
                            }
                        }
                        downloadPopup.addAction(reinstallAction)
                    }
                } else if let hasRepoPackage = PackageListManager.shared.newestPackage(identifier: package.package) {
                    let reinstallAction = UIAlertAction(title: String(localizationKey: "Package_Reinstall_Action"), style: .default) { _ in
                        downloadPopup.dismiss(animated: false) {
                            self.showVersionPrompt(nil)
                        }
                    }
                    downloadPopup.addAction(reinstallAction)
                }
//            }

            let removeAction = UIAlertAction(title: String(localizationKey: "Package_Uninstall_Action"), style: .default, handler: { _ in
                self.requestQueuePackage(package: package, queue: .uninstallations)
            })
            downloadPopup.addAction(removeAction)
            let cancelAction: UIAlertAction! = UIAlertAction(title: String(localizationKey: "Package_Cancel_Action"), style: .cancel)
            downloadPopup.addAction(cancelAction)
            if UIDevice.current.userInterfaceIdiom == .pad {
                downloadPopup.popoverPresentationController?.sourceView = self
            }
            let tintColor: UIColor! = self.tintColor
            if tintColor != nil {
                downloadPopup.view.tintColor = tintColor
            }
            self.viewControllerForPresentation?.present(downloadPopup, animated: true, completion: {
                if tintColor != nil {
                    downloadPopup.view.tintColor = tintColor
                }
            })
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
extension PackageQueueButton: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let package = package, !(package.isProvisional ?? false) else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            let actions = self.longPressMenuItems(for: package).map { item in
                UIAction(title: item.title, image: UIImage(systemName: item.image)) { _ in
                    item.handler()
                }
            }
            return UIMenu(title: package.name, children: actions)
        }
    }
}

private final class PackageVersionPickerController: UITableViewController {
    private let sections: [(title: String, packages: [Package])]
    private let onPick: (Package) -> Void

    init(sections: [(title: String, packages: [Package])], onPick: @escaping (Package) -> Void) {
        self.sections = sections
        self.onPick = onPick
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localizationKey: "Select Version")
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
        cell.backgroundColor = .clear
        return cell
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

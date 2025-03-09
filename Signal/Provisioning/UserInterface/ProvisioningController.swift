//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

class ProvisioningNavigationController: OWSNavigationController {
    private(set) var provisioningController: ProvisioningController

    init(provisioningController: ProvisioningController) {
        self.provisioningController = provisioningController
        super.init()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        let superOrientations = super.supportedInterfaceOrientations
        let provisioningOrientations: UIInterfaceOrientationMask = UIDevice.current.isIPad ? .all : .portrait

        return superOrientations.intersection(provisioningOrientations)
    }
}

class ProvisioningController: NSObject {

    private struct ProvisioningUrlParams {
        let uuid: String
        let cipher: ProvisioningCipher
    }

    private struct DecryptableProvisionEnvelope {
        let cipher: ProvisioningCipher
        let envelope: ProvisioningProtoProvisionEnvelope

        func decrypt() throws -> ProvisionMessage {
            return try cipher.decrypt(envelope: envelope)
        }
    }

    /// Represents an attempt to communicate with the primary.
    private struct ProvisioningUrlCommunicationAttempt {
        /// The socket from which we hope to receive a provisioning envelope
        /// from a primary.
        let socket: ProvisioningSocket
        /// The cipher to be used in encrypting the provisioning envelope.
        let cipher: ProvisioningCipher
        /// A continuation waiting for us to fetch the parameters necessary for
        /// us to construct a provisioning URL, which we will present to the
        /// primary via QR code. The provisioning URL will contain the necessary
        /// data for the primary to send us a provisioning envelope over our
        /// provisioning socket, via the server.
        var fetchProvisioningUrlParamsContinuation: CheckedContinuation<ProvisioningUrlParams, Error>?
    }

    private var urlCommunicationAttempts: AtomicValue<[ProvisioningUrlCommunicationAttempt]> = AtomicValue([], lock: .init())
    private var awaitProvisionEnvelopeContinuation: AtomicValue<CheckedContinuation<DecryptableProvisionEnvelope?, Never>?> = AtomicValue(nil, lock: .init())

    private let appReadiness: AppReadinessSetter

    private lazy var provisioningCoordinator: ProvisioningCoordinator = {
        return ProvisioningCoordinatorImpl(
            chatConnectionManager: DependenciesBridge.shared.chatConnectionManager,
            db: DependenciesBridge.shared.db,
            deviceService: DependenciesBridge.shared.deviceService,
            identityManager: DependenciesBridge.shared.identityManager,
            linkAndSyncManager: DependenciesBridge.shared.linkAndSyncManager,
            accountKeyStore: DependenciesBridge.shared.accountKeyStore,
            messageFactory: ProvisioningCoordinatorImpl.Wrappers.MessageFactory(),
            preKeyManager: DependenciesBridge.shared.preKeyManager,
            profileManager: ProvisioningCoordinatorImpl.Wrappers.ProfileManager(SSKEnvironment.shared.profileManagerImplRef),
            pushRegistrationManager: ProvisioningCoordinatorImpl.Wrappers.PushRegistrationManager(AppEnvironment.shared.pushRegistrationManagerRef),
            receiptManager: ProvisioningCoordinatorImpl.Wrappers.ReceiptManager(SSKEnvironment.shared.receiptManagerRef),
            registrationStateChangeManager: DependenciesBridge.shared.registrationStateChangeManager,
            signalProtocolStoreManager: DependenciesBridge.shared.signalProtocolStoreManager,
            signalService: SSKEnvironment.shared.signalServiceRef,
            storageServiceManager: SSKEnvironment.shared.storageServiceManagerRef,
            svr: DependenciesBridge.shared.svr,
            syncManager: ProvisioningCoordinatorImpl.Wrappers.SyncManager(SSKEnvironment.shared.syncManagerRef),
            threadStore: ThreadStoreImpl(),
            tsAccountManager: DependenciesBridge.shared.tsAccountManager,
            udManager: ProvisioningCoordinatorImpl.Wrappers.UDManager(SSKEnvironment.shared.udManagerRef)
        )
    }()

    private init(appReadiness: AppReadinessSetter) {
        self.appReadiness = appReadiness

        super.init()
    }

    static func presentProvisioningFlow(appReadiness: AppReadinessSetter) {
        let provisioningController = ProvisioningController(appReadiness: appReadiness)
        let navController = ProvisioningNavigationController(provisioningController: provisioningController)
        provisioningController.setUpDebugLogsGesture(on: navController)

        let vc = ProvisioningSplashViewController(provisioningController: provisioningController)
        navController.setViewControllers([vc], animated: false)

        CurrentAppContext().mainWindow?.rootViewController = navController
    }

    static func presentRelinkingFlow(appReadiness: AppReadinessSetter) {
        let provisioningController = ProvisioningController(appReadiness: appReadiness)
        let navController = ProvisioningNavigationController(provisioningController: provisioningController)
        provisioningController.setUpDebugLogsGesture(on: navController)

        let vc = ProvisioningQRCodeViewController(provisioningController: provisioningController)
        navController.setViewControllers([vc], animated: false)
        CurrentAppContext().mainWindow?.rootViewController = navController

        Task {
            await provisioningController.awaitProvisioning(
                from: vc,
                navigationController: navController
            )
        }
    }

#if DEBUG
    static func preview() -> ProvisioningController {
        ProvisioningController(appReadiness: AppReadinessMock())
    }
#endif

    private func setUpDebugLogsGesture(
        on navigationController: UINavigationController
    ) {
        let submitLogsGesture = UITapGestureRecognizer(target: self, action: #selector(submitLogs))
        submitLogsGesture.numberOfTapsRequired = 8
        submitLogsGesture.delaysTouchesEnded = false
        navigationController.view.addGestureRecognizer(submitLogsGesture)
    }

    @objc
    private func submitLogs() {
        DebugLogs.submitLogsWithSupportTag("Onboarding")
    }

    // MARK: - Transitions

    func provisioningSplashRequestedModeSwitch(viewController: UIViewController) {
        AssertIsOnMainThread()

        Logger.info("")

        let view = ProvisioningModeSwitchConfirmationViewController(provisioningController: self)
        viewController.navigationController?.pushViewController(view, animated: true)
    }

    func switchToPrimaryRegistration(viewController: UIViewController) {
        AssertIsOnMainThread()

        Logger.info("")
        let loader = RegistrationCoordinatorLoaderImpl(dependencies: .from(self))
        SignalApp.shared.showRegistration(loader: loader, desiredMode: .registering, appReadiness: appReadiness)
    }

    @MainActor
    func provisioningSplashDidComplete(viewController: UIViewController) async {
        Logger.info("")
        await pushPermissionsViewOrSkipToRegistration(onto: viewController)
    }

    @MainActor
    private func pushPermissionsViewOrSkipToRegistration(onto oldViewController: UIViewController) async {
        // Disable interaction during the asynchronous operation.
        oldViewController.view.isUserInteractionEnabled = false

        let newViewController = ProvisioningPermissionsViewController(provisioningController: self)
        let needsToAskForAnyPermissions = await newViewController.needsToAskForAnyPermissions()

        // Always re-enable interaction in case the user restart registration.
        oldViewController.view.isUserInteractionEnabled = true

        if needsToAskForAnyPermissions {
            oldViewController.navigationController?.pushViewController(newViewController, animated: true)
        } else {
            self.provisioningPermissionsDidComplete(viewController: oldViewController)
        }
    }

    func provisioningPermissionsDidComplete(viewController: UIViewController) {
        AssertIsOnMainThread()

        Logger.info("")

        guard let navigationController = viewController.navigationController else {
            owsFailDebug("navigationController was unexpectedly nil")
            return
        }

        pushTransferChoiceView(onto: navigationController)
    }

    func pushTransferChoiceView(onto navigationController: UINavigationController) {
        AssertIsOnMainThread()

        let view = ProvisioningTransferChoiceViewController(provisioningController: self)
        navigationController.pushViewController(view, animated: true)
    }

    // MARK: - Transfer

    func transferAccount(fromViewController: UIViewController) {
        AssertIsOnMainThread()

        Logger.info("")

        guard let navigationController = fromViewController.navigationController else {
            owsFailDebug("Missing navigationController")
            return
        }

        guard !(navigationController.topViewController is ProvisioningTransferQRCodeViewController) else {
            // qr code view is already presented, we don't need to push it again.
            return
        }

        let view = ProvisioningTransferQRCodeViewController(provisioningController: self)
        navigationController.pushViewController(view, animated: true)
    }

    func accountTransferInProgress(fromViewController: UIViewController, progress: Progress) {
        AssertIsOnMainThread()

        Logger.info("")

        guard let navigationController = fromViewController.navigationController else {
            owsFailDebug("Missing navigationController")
            return
        }

        guard !(navigationController.topViewController is ProvisioningTransferProgressViewController) else {
            // qr code view is already presented, we don't need to push it again.
            return
        }

        let view = ProvisioningTransferProgressViewController(provisioningController: self, progress: progress)
        navigationController.pushViewController(view, animated: true)
    }

    // MARK: - Linking

    func didConfirmSecondaryDevice(from viewController: ProvisioningPrepViewController) {
        guard let navigationController = viewController.navigationController else {
            owsFailDebug("navigationController was unexpectedly nil")
            return
        }

        let qrCodeViewController = ProvisioningQRCodeViewController(provisioningController: self)
        navigationController.pushViewController(qrCodeViewController, animated: true)

        Task {
            await awaitProvisioning(
                from: qrCodeViewController,
                navigationController: navigationController
            )
        }
    }

    private func awaitProvisioning(
        from viewController: ProvisioningQRCodeViewController,
        navigationController: UINavigationController
    ) async {
        let decryptableProvisionEnvelope: DecryptableProvisionEnvelope? = await withCheckedContinuation { newContinuation in
            awaitProvisionEnvelopeContinuation.update { existingContinuation in
                guard existingContinuation == nil else {
                    newContinuation.resume(returning: nil)
                    return
                }

                existingContinuation = newContinuation
            }
        }

        guard let decryptableProvisionEnvelope else {
            owsFailDebug("Attempted to await provisioning multiple times!")
            return
        }

        await MainActor.run {
            let provisionMessage: ProvisionMessage
            do {
                provisionMessage = try decryptableProvisionEnvelope.decrypt()
            } catch let error {
                Logger.error("Failed to decrypt provision envelope: \(error)")

                let alert = ActionSheetController(
                    title: OWSLocalizedString(
                        "SECONDARY_LINKING_ERROR_WAITING_FOR_SCAN",
                        comment: "alert title"
                    ),
                    message: error.userErrorDescription
                )
                alert.addAction(ActionSheetAction(
                    title: CommonStrings.cancelButton,
                    style: .cancel,
                    handler: { _ in
                        navigationController.popViewController(animated: true)
                    }
                ))

                navigationController.presentActionSheet(alert)
                return
            }

            /// Ensure the primary is new enough to link us.
            guard
                let provisioningVersion = provisionMessage.provisioningVersion,
                provisioningVersion >= OWSDeviceProvisionerConstant.provisioningVersion
            else {
                OWSActionSheets.showActionSheet(
                    title: OWSLocalizedString(
                        "SECONDARY_LINKING_ERROR_OLD_VERSION_TITLE",
                        comment: "alert title for outdated linking device"
                    ),
                    message: OWSLocalizedString(
                        "SECONDARY_LINKING_ERROR_OLD_VERSION_MESSAGE",
                        comment: "alert message for outdated linking device"
                    )
                ) { _ in
                    navigationController.popViewController(animated: true)
                }
                return
            }

            if FeatureFlags.linkAndSyncLinkedImport {
                // Don't confirm the name in link'n'sync, just keep going.
                didSetDeviceName(
                    UIDevice.current.name,
                    provisionMessage: provisionMessage,
                    from: viewController,
                    navigationController: navigationController,
                    willLinkAndSync: provisionMessage.ephemeralBackupKey != nil
                )
            } else {
                let confirmVC = ProvisioningSetDeviceNameViewController(
                    provisionMessage: provisionMessage,
                    provisioningController: self,
                    qrCodeViewController: viewController
                )
                navigationController.pushViewController(confirmVC, animated: true)
            }
        }
    }

    func didSetDeviceName(
        _ deviceName: String,
        provisionMessage: ProvisionMessage,
        from viewController: ProvisioningQRCodeViewController,
        navigationController: UINavigationController,
        willLinkAndSync: Bool
    ) {
        let progressViewModel = LinkAndSyncSecondaryProgressViewModel()

        performCoordinatorTaskWithModal(
            task: Task {
                try await self.provisioningCoordinator.completeProvisioning(
                    provisionMessage: provisionMessage,
                    deviceName: deviceName,
                    progressViewModel: progressViewModel
                )
            },
            viewController: viewController,
            navigationController: navigationController,
            willLinkAndSync: willLinkAndSync,
            progressViewModel: progressViewModel
        )
    }

    func provisioningDidComplete(from viewController: UIViewController) {
        SignalApp.shared.showConversationSplitView(appReadiness: appReadiness)
    }

    @MainActor
    private func resetBackToQrCodeController(
        from viewController: ProvisioningQRCodeViewController,
        navigationController: UINavigationController
    ) {
        Logger.warn("")

        // Reset at the start so it goes while other stuff animates.
        viewController.reset()

        func popAndThenAwaitProvisioning() {
            if navigationController.presentedViewController != nil {
                navigationController.dismiss(animated: true, completion: {
                    popAndThenAwaitProvisioning()
                })
                return
            }
            navigationController.popToViewController(viewController, animated: true)
            Task {
                await awaitProvisioning(
                    from: viewController,
                    navigationController: navigationController
                )
            }
        }
        popAndThenAwaitProvisioning()
    }

    /// Opens a new provisioning socket. Note that the server closes
    /// provisioning sockets after 90s, so callers must ensure that they do not
    /// need the socket longer than that.
    ///
    /// - Returns
    /// A provisioning URL containing information about the now-opened
    /// provisioning socket.
    func openNewProvisioningSocket() async throws -> URL {
        let provisioningUrlParams: ProvisioningUrlParams = try await withCheckedThrowingContinuation { paramsContinuation in
            let newAttempt = ProvisioningUrlCommunicationAttempt(
                socket: ProvisioningSocket(),
                cipher: .generate(),
                fetchProvisioningUrlParamsContinuation: paramsContinuation
            )

            urlCommunicationAttempts.update { $0.append(newAttempt) }

            newAttempt.socket.delegate = self
            newAttempt.socket.connect()
        }

        return try Self.buildProvisioningUrl(params: provisioningUrlParams)
    }

    private func performCoordinatorTaskWithModal(
        task: Task<Void, Error>,
        viewController: ProvisioningQRCodeViewController,
        navigationController: UINavigationController,
        willLinkAndSync: Bool,
        progressViewModel: LinkAndSyncSecondaryProgressViewModel
    ) {
        if willLinkAndSync {
            Task { @MainActor in
                let progressViewController: LinkAndSyncProvisioningProgressViewController
                if let vc = viewController.presentedViewController {
                    if let vc = vc as? LinkAndSyncProvisioningProgressViewController {
                        progressViewController = vc
                    } else {
                        vc.dismiss(animated: true, completion: {
                            self.performCoordinatorTaskWithModal(
                                task: task,
                                viewController: viewController,
                                navigationController: navigationController,
                                willLinkAndSync: willLinkAndSync,
                                progressViewModel: progressViewModel
                            )
                        })
                        return
                    }
                } else {
                    progressViewController = LinkAndSyncProvisioningProgressViewController(viewModel: progressViewModel)
                }
                progressViewController.linkNSyncTask = task
                viewController.present(progressViewController, animated: false)
                do {
                    try await task.value
                    // Don't dismiss the progress view or it will quickly jump
                    // to that before jumping again to the chat list.
                    self.provisioningDidComplete(from: viewController)
                } catch var error as CompleteProvisioningError {
                    if case let .linkAndSyncError(provisioningLinkAndSyncError) = error {
                        switch provisioningLinkAndSyncError.error {
                        case .primaryFailedBackupExport(let continueWithoutSyncing):
                            if continueWithoutSyncing {
                                do {
                                    try await provisioningLinkAndSyncError.continueWithoutSyncing()
                                    self.provisioningDidComplete(from: viewController)
                                    return
                                } catch let innerError as CompleteProvisioningError {
                                    error = innerError
                                }
                            } else {
                                // Crash if this fails; things have gone horribly wrong.
                                try! await provisioningLinkAndSyncError.restartProvisioning()
                                self.resetBackToQrCodeController(
                                    from: viewController,
                                    navigationController: navigationController
                                )
                                return
                            }
                        case .cancelled:
                            // Exit provisioning if we cancelled
                            do {
                                try await provisioningLinkAndSyncError.continueWithoutSyncing()
                                self.provisioningDidComplete(from: viewController)
                                return
                            } catch let innerError as CompleteProvisioningError {
                                error = innerError
                            }
                        default:
                            break
                        }
                    }
                    let errorActionSheet = self.errorActionSheet(
                        error: error,
                        from: viewController,
                        navigationController: navigationController,
                        progressViewModel: progressViewModel
                    )
                    progressViewController.presentActionSheet(errorActionSheet)
                }
            }
        } else {
            let presentingController = viewController.presentedViewController ?? viewController
            ModalActivityIndicatorViewController.present(
                fromViewController: presentingController,
                canCancel: false
            ) { modal async -> Void in
                let result: CompleteProvisioningError?
                do {
                    try await task.value
                    result = nil
                } catch let error {
                    result = error as? CompleteProvisioningError
                }

                let errorActionSheet = result.map {
                    self.errorActionSheet(
                        error: $0,
                        from: viewController,
                        navigationController: navigationController,
                        progressViewModel: progressViewModel
                    )
                }
                modal.dismiss {
                    if let errorActionSheet {
                        presentingController.presentActionSheet(errorActionSheet)
                    } else {
                        self.provisioningDidComplete(from: viewController)
                    }
                }
            }
        }
    }

    private func errorActionSheet(
        error: CompleteProvisioningError,
        from viewController: ProvisioningQRCodeViewController,
        navigationController: UINavigationController,
        progressViewModel: LinkAndSyncSecondaryProgressViewModel
    ) -> ActionSheetController {
        let alert: ActionSheetController
        switch error {
        case .previouslyLinkedWithDifferentAccount:
            Logger.warn("was previously linked/registered on different account!")
            let title = OWSLocalizedString(
                "SECONDARY_LINKING_ERROR_DIFFERENT_ACCOUNT_TITLE",
                comment: "Title for error alert indicating that re-linking failed because the account did not match."
            )
            let message = OWSLocalizedString(
                "SECONDARY_LINKING_ERROR_DIFFERENT_ACCOUNT_MESSAGE",
                comment: "Message for error alert indicating that re-linking failed because the account did not match."
            )
            alert = ActionSheetController(title: title, message: message)
            alert.addAction(ActionSheetAction(
                title: OWSLocalizedString(
                    "SECONDARY_LINKING_ERROR_DIFFERENT_ACCOUNT_RESET_DEVICE",
                    comment: "Label for the 'reset device' action in the 're-linking failed because the account did not match' alert."
                ),
                accessibilityIdentifier: "alert.reset_device",
                style: .default,
                handler: { _ in
                    self.resetBackToQrCodeController(
                        from: viewController,
                        navigationController: navigationController
                    )
                }
            ))
        case .deviceLimitExceededError(let error):
            alert = ActionSheetController(title: error.errorDescription, message: error.recoverySuggestion)
            alert.addAction(ActionSheetAction(
                title: CommonStrings.okButton,
                handler: { _ in
                    self.resetBackToQrCodeController(
                        from: viewController,
                        navigationController: navigationController
                    )
                }
            ))
        case .obsoleteLinkedDeviceError:
            Logger.warn("obsolete device error")
            let title = OWSLocalizedString(
                "SECONDARY_LINKING_ERROR_OBSOLETE_LINKED_DEVICE_TITLE",
                comment: "Title for error alert indicating that a linked device must be upgraded before it can be linked."
            )
            let message = OWSLocalizedString(
                "SECONDARY_LINKING_ERROR_OBSOLETE_LINKED_DEVICE_MESSAGE",
                comment: "Message for error alert indicating that a linked device must be upgraded before it can be linked."
            )
            alert = ActionSheetController(title: title, message: message)

            let updateButtonText = OWSLocalizedString(
                "APP_UPDATE_NAG_ALERT_UPDATE_BUTTON",
                comment: "Label for the 'update' button in the 'new app version available' alert."
            )
            let updateAction = ActionSheetAction(
                title: updateButtonText,
                accessibilityIdentifier: "alert.update",
                style: .default
            ) { _ in
                let url = TSConstants.appStoreUrl
                UIApplication.shared.open(url, options: [:])
            }
            alert.addAction(updateAction)
        case .genericError(let error):
            let title = OWSLocalizedString("SECONDARY_LINKING_ERROR_WAITING_FOR_SCAN", comment: "alert title")
            let message = error.userErrorDescription
            alert = ActionSheetController(title: title, message: message)
            alert.addAction(ActionSheetAction(
                title: CommonStrings.retryButton,
                accessibilityIdentifier: "alert.retry",
                style: .default,
                handler: { _ in
                    let isProvisioned = DependenciesBridge.shared.db.read { tx in
                        DependenciesBridge.shared.tsAccountManager.registrationState(tx: tx).isRegistered
                    }
                    if isProvisioned {
                        self.provisioningDidComplete(from: viewController)
                    } else {
                        self.resetBackToQrCodeController(
                            from: viewController,
                            navigationController: navigationController
                        )
                    }
                }
            ))
        case .linkAndSyncError(let error):
            return self.linkAndSyncRetryActionSheet(
                error: error,
                from: viewController,
                navigationController: navigationController,
                progressViewModel: progressViewModel
            )
        }
        return alert
    }

    private func linkAndSyncRetryActionSheet(
        error: ProvisioningLinkAndSyncError,
        from viewController: ProvisioningQRCodeViewController,
        navigationController: UINavigationController,
        progressViewModel: LinkAndSyncSecondaryProgressViewModel
    ) -> ActionSheetController {
        enum ErrorPromptMode {
            case contactSupport
            case networkErrorRetry
            case restartProvisioning
        }

        let errorPromptMode: ErrorPromptMode
        let errorMessage: String?
        switch error.error {
        case .errorRestoringBackup:
            errorPromptMode = .contactSupport
            errorMessage = nil
        case .errorDownloadingBackup, .networkError:
            errorPromptMode = .networkErrorRetry
            errorMessage = OWSLocalizedString(
                "SECONDARY_LINKING_SYNCING_NETWORK_ERROR_MESSAGE",
                comment: "Message for action sheet when secondary device fails to sync messages due to network error."
            )
        case .primaryFailedBackupExport:
            owsFailDebug("No prompt for this case")
            fallthrough
        case .errorWaitingForBackup, .cancelled:
            errorPromptMode = .restartProvisioning
            errorMessage = OWSLocalizedString(
                "SECONDARY_LINKING_SYNCING_OTHER_ERROR_MESSAGE",
                comment: "Message for action sheet when secondary device fails to sync messages due to an unspecified error."
            )
        case .unsupportedBackupVersion:
            let actionSheet = ActionSheetController(
                title: OWSLocalizedString(
                    "SECONDARY_LINKING_SYNCING_UPDATE_REQUIRED_ERROR_TITLE",
                    comment: "Title for action sheet when the secondary device fails to sync messages due to an app update being required."
                ),
                message: OWSLocalizedString(
                    "SECONDARY_LINKING_SYNCING_UPDATE_REQUIRED_ERROR_MESSAGE",
                    comment: "Message for action sheet when the secondary device fails to sync messages due to an app update being required."
                )
            )

            actionSheet.addAction(ActionSheetAction(
                title: OWSLocalizedString(
                    "SECONDARY_LINKING_SYNCING_UPDATE_REQUIRED_CHECK_FOR_UPDATE_BUTTON",
                    comment: "Button on an action sheet to open Signal on the App Store."
                ),
                style: .default
            ) { _ in
                UIApplication.shared.open(TSConstants.appStoreUrl)
                Task { @MainActor in
                    // Crash if this fails; things have gone horribly wrong.
                    try! await error.restartProvisioning()
                    self.resetBackToQrCodeController(
                        from: viewController,
                        navigationController: navigationController
                    )
                }
            })
            return actionSheet
        }

        let retryActionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "SECONDARY_LINKING_SYNCING_ERROR_TITLE",
                comment: "Title for action sheet when secondary device fails to sync messages."
            ),
            message: errorMessage
        )
        retryActionSheet.isCancelable = false

        switch errorPromptMode {
        case .contactSupport:
            retryActionSheet.addAction(ActionSheetAction(title: CommonStrings.contactSupport) { _ in
                Task { @MainActor in
                    // Crash if this fails; things have gone horribly wrong.
                    try! await error.restartProvisioning()
                    self.resetBackToQrCodeController(
                        from: viewController,
                        navigationController: navigationController
                    )

                    // Wait to present until we've reset back to the QR code
                    // view controller.
                    ContactSupportActionSheet.present(
                        emailFilter: .backupImportFailed,
                        fromViewController: viewController
                    )
                }
            })
        case .networkErrorRetry:
            retryActionSheet.addAction(ActionSheetAction(title: CommonStrings.retryButton) { _ in
                self.performCoordinatorTaskWithModal(
                    task: Task {
                        try await error.retryLinkAndSync()
                    },
                    viewController: viewController,
                    navigationController: navigationController,
                    willLinkAndSync: true,
                    progressViewModel: progressViewModel
                )
            })
        case .restartProvisioning:
            retryActionSheet.addAction(ActionSheetAction(title: CommonStrings.retryButton) { _ in
                Task { @MainActor in
                    // Crash if this fails; things have gone horribly wrong.
                    try! await error.restartProvisioning()
                    self.resetBackToQrCodeController(
                        from: viewController,
                        navigationController: navigationController
                    )
                }
            })
        }

        retryActionSheet.addAction(ActionSheetAction(
            title: CommonStrings.cancelButton,
            style: .cancel
        ) { _ in
            self.performCoordinatorTaskWithModal(
                task: Task {
                    try await error.continueWithoutSyncing()
                },
                viewController: viewController,
                navigationController: navigationController,
                willLinkAndSync: false,
                progressViewModel: progressViewModel
            )
        })

        return retryActionSheet
    }

    // MARK: -

    private static func buildProvisioningUrl(params: ProvisioningUrlParams) throws -> URL {
        let base64PubKey: String = Data(
            params.cipher.secondaryDevicePublicKey.serialize()
        ).base64EncodedString()
        guard let encodedPubKey = base64PubKey.encodeURIComponent else {
            throw OWSAssertionError("Failed to url encode query params")
        }

        var capabilities = [String]()

        let shouldLinkAndSync: Bool = {
            switch DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction {
            case .unregistered:
                return FeatureFlags.linkAndSyncLinkedImport
            case .delinked, .relinking:
                // We don't allow relinking secondaries to link'n'sync.
                return false
            case
                .registered,
                .provisioned,
                .reregistering,
                .transferred,
                .transferringIncoming,
                .transferringLinkedOutgoing,
                .transferringPrimaryOutgoing,
                .deregistered:
                owsFailDebug("How are we provisioning from this state?")
                return false
            }
        }()

        if shouldLinkAndSync {
            capabilities.append(DeviceProvisioningURL.Capability.linknsync.rawValue)
        }

        // We don't use URLComponents to generate this URL as it encodes '+' and '/'
        // in the base64 pub_key in a way the Android doesn't tolerate.
        var urlString = UrlOpener.Constants.sgnlPrefix
        urlString.append("://")
        urlString.append(DeviceProvisioningURL.Constants.linkDeviceHost)
        urlString.append("?\(DeviceProvisioningURL.uuidParamName)=\(params.uuid)")
        urlString.append("&\(DeviceProvisioningURL.publicKeyParamName)=\(encodedPubKey)")
        urlString.append("&\(DeviceProvisioningURL.capabilitiesParamName)=\(capabilities.joined(separator: ","))")
        guard let url = URL(string: urlString) else {
            throw OWSAssertionError("invalid url: \(urlString)")
        }

        return url
    }
}

extension ProvisioningController: ProvisioningSocketDelegate {
    func provisioningSocket(_ provisioningSocket: ProvisioningSocket, didReceiveProvisioningUuid provisioningUuid: String) {
        urlCommunicationAttempts.update { attempts in
            let matchingAttemptIndex = attempts.firstIndex {
                $0.socket.id == provisioningSocket.id
            }

            guard
                let matchingAttemptIndex,
                let fetchParamsContinuation = attempts[matchingAttemptIndex].fetchProvisioningUrlParamsContinuation
            else {
                owsFailDebug("Got provisioning UUID for unknown socket!")
                return
            }

            attempts[matchingAttemptIndex].fetchProvisioningUrlParamsContinuation = nil

            fetchParamsContinuation.resume(
                returning: ProvisioningUrlParams(
                    uuid: provisioningUuid,
                    cipher: attempts[matchingAttemptIndex].cipher
                )
            )
        }
    }

    func provisioningSocket(_ provisioningSocket: ProvisioningSocket, didReceiveEnvelope envelope: ProvisioningProtoProvisionEnvelope) {
        var cipherForSocket: ProvisioningCipher?

        /// We've gotten a provisioning message, from one of our attempts'
        /// sockets. (We don't care which one – it's whichever one the primary
        /// scanned and sent an envelope through!)
        for attempt in urlCommunicationAttempts.get() {
            /// After we get a provisioning message, we don't expect anything
            /// from this or any other socket.
            attempt.socket.disconnect(code: .normalClosure)

            if provisioningSocket.id == attempt.socket.id {
                owsAssertDebug(
                    cipherForSocket == nil,
                    "Extracting cipher, but unexpectedly already set from previous match!"
                )

                cipherForSocket = attempt.cipher
            }
        }

        guard let cipherForSocket else {
            owsFailDebug("Missing cipher for socket that received envelope!")
            return
        }

        awaitProvisionEnvelopeContinuation.update { continuation in
            guard continuation != nil else {
                owsFailDebug("Got provision envelope, but missing continuation or cipher!")
                return
            }

            continuation!.resume(returning: DecryptableProvisionEnvelope(
                cipher: cipherForSocket,
                envelope: envelope
            ))
            continuation = nil
        }
    }

    func provisioningSocket(_ provisioningSocket: ProvisioningSocket, didError error: Error) {
        if
            let webSocketError = error as? WebSocketError,
            case .closeError = webSocketError
        {
            Logger.info("Provisioning socket closed...")
        } else {
            Logger.error("\(error)")
        }

        urlCommunicationAttempts.update { attempts in
            let matchingAttemptIndex = attempts.firstIndex {
                $0.socket.id == provisioningSocket.id
            }

            guard let matchingAttemptIndex else {
                owsFailDebug("Got provisioning UUID for unknown socket!")
                return
            }

            attempts[matchingAttemptIndex].fetchProvisioningUrlParamsContinuation?.resume(throwing: error)
            attempts[matchingAttemptIndex].fetchProvisioningUrlParamsContinuation = nil
        }
    }
}

private extension CommonStrings {
    static var linkNSyncImportErrorTitle: String {
        OWSLocalizedString(
            "SECONDARY_LINKING_SYNCING_ERROR_TITLE",
            comment: "Title for action sheet when secondary device fails to sync messages."
        )
    }
}

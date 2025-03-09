//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI

protocol LinkDeviceViewControllerDelegate: AnyObject {
    typealias LinkNSyncData = (ephemeralBackupKey: BackupKey, tokenId: DeviceProvisioningTokenId)
    @MainActor
    func didFinishLinking(_ linkNSyncData: LinkNSyncData?, from linkDeviceViewController: LinkDeviceViewController)
}

class LinkDeviceViewController: OWSViewController {

    weak var delegate: LinkDeviceViewControllerDelegate?

    private var hasShownEducationSheet: Bool
    private weak var educationSheet: HeroSheetViewController?

    private lazy var qrCodeScanViewController = QRCodeScanViewController(appearance: .framed)

    init(skipEducationSheet: Bool) {
        self.hasShownEducationSheet = skipEducationSheet
        super.init()
    }

    // MARK: QRCodeScanOrPickDelegate

    var selectedAttachment: ImagePickerAttachment?

    // MARK: -

    override func viewDidLoad() {
        super.viewDidLoad()

        title = CommonStrings.scanQRCodeTitle

#if TESTABLE_BUILD
        navigationItem.rightBarButtonItem = .init(
            title: LocalizationNotNeeded("ENTER"),
            style: .plain,
            target: self,
            action: #selector(manuallyEnterLinkURL)
        )
#endif

        qrCodeScanViewController.delegate = self

        addChild(qrCodeScanViewController)
        view.addSubview(qrCodeScanViewController.view)

        qrCodeScanViewController.view.autoPinEdgesToSuperviewEdges()
        qrCodeScanViewController.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !UIDevice.current.isIPad {
            UIDevice.current.ows_setOrientation(.portrait)
        }

        if !hasShownEducationSheet {
            let animationName = if traitCollection.userInterfaceStyle == .dark {
                "linking-device-dark"
            } else {
                "linking-device-light"
            }

            let sheet = HeroSheetViewController(
                heroAnimationName: animationName,
                heroAnimationHeight: 192,
                title: OWSLocalizedString(
                    "LINK_DEVICE_SCANNING_INSTRUCTIONS_SHEET_TITLE",
                    comment: "Title for QR Scanning screen instructions sheet"
                ),
                body: OWSLocalizedString(
                    "LINK_DEVICE_SCANNING_INSTRUCTIONS_SHEET_BODY",
                    comment: "Title for QR Scanning screen instructions sheet"
                ),
                buttonTitle: CommonStrings.okayButton
            )

            DispatchQueue.main.async {
                self.present(sheet, animated: true)
                self.hasShownEducationSheet = true
                self.educationSheet = sheet
            }
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.isIPad ? .all : .portrait
    }

    private func dismissEducationSheetIfNecessary(completion: @escaping () -> Void) {
        if let educationSheet {
            educationSheet.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    private func safePresent(_ viewController: UIViewController) {
        dismissEducationSheetIfNecessary { [weak self] in
            self?.present(viewController, animated: true)
        }
    }

    // MARK: -

    private func confirmProvisioningWithUrl(_ deviceProvisioningUrl: DeviceProvisioningURL) {
        if FeatureFlags.linkAndSyncPrimaryExport, deviceProvisioningUrl.capabilities.contains(.linknsync) {
            let linkOrSyncSheet = LinkOrSyncPickerSheet {
                self.popToLinkedDeviceList()
            } linkAndSync: {
                self.provisionWithUrl(deviceProvisioningUrl, shouldLinkNSync: true)
            } linkOnly: {
                self.provisionWithUrl(deviceProvisioningUrl, shouldLinkNSync: false)
            }

            self.safePresent(linkOrSyncSheet)
        } else {
            let title = NSLocalizedString(
                "LINK_DEVICE_PERMISSION_ALERT_TITLE",
                comment: "confirm the users intent to link a new device"
            )
            let linkingDescription = NSLocalizedString(
                "LINK_DEVICE_PERMISSION_ALERT_BODY",
                comment: "confirm the users intent to link a new device"
            )

            let actionSheet = ActionSheetController(title: title, message: linkingDescription)
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.cancelButton,
                style: .cancel,
                handler: { _ in
                    DispatchQueue.main.async {
                        self.popToLinkedDeviceList()
                    }
                }
            ))
            actionSheet.addAction(ActionSheetAction(
                title: NSLocalizedString("CONFIRM_LINK_NEW_DEVICE_ACTION", comment: "Button text"),
                style: .default,
                handler: { _ in
                    self.provisionWithUrl(deviceProvisioningUrl, shouldLinkNSync: false)
                }
            ))
            safePresent(actionSheet)
        }
    }

    private func provisionWithUrl(
        _ deviceProvisioningUrl: DeviceProvisioningURL,
        shouldLinkNSync: Bool
    ) {
        SSKEnvironment.shared.databaseStorageRef.write { transaction in
            // Optimistically set this flag.
            DependenciesBridge.shared.deviceManager.setMightHaveUnknownLinkedDevice(
                true,
                transaction: transaction.asV2Write
            )
        }

        struct ProvisioningState {
            var localIdentifiers: LocalIdentifiers
            var aciIdentityKeyPair: ECKeyPair
            var pniIdentityKeyPair: ECKeyPair
            var areReadReceiptsEnabled: Bool
            var rootKey: OWSDeviceProvisioner.RootKey
            var mediaRootBackupKey: BackupKey
            var profileKey: Aes256Key
        }

        let ephemeralBackupKey: BackupKey?
        if
            FeatureFlags.linkAndSyncPrimaryExport,
            shouldLinkNSync,
            deviceProvisioningUrl.capabilities.contains(where: { $0 == .linknsync })
        {
            ephemeralBackupKey = DependenciesBridge.shared.linkAndSyncManager.generateEphemeralBackupKey()
        } else {
            ephemeralBackupKey = nil
        }

        let provisioningState = SSKEnvironment.shared.databaseStorageRef.write { tx in
            guard let localIdentifiers = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx.asV2Read) else {
                owsFail("Can't provision without an aci & phone number.")
            }
            let identityManager = DependenciesBridge.shared.identityManager
            guard let aciIdentityKeyPair = identityManager.identityKeyPair(for: .aci, tx: tx.asV2Read) else {
                owsFail("Can't provision without an aci identity.")
            }
            guard let pniIdentityKeyPair = identityManager.identityKeyPair(for: .pni, tx: tx.asV2Read) else {
                owsFail("Can't provision without a pni identity.")
            }
            let areReadReceiptsEnabled = OWSReceiptManager.areReadReceiptsEnabled(transaction: tx)
            let rootKey: OWSDeviceProvisioner.RootKey
            if FeatureFlags.enableAccountEntropyPool {
                guard let accountEntropyPool = DependenciesBridge.shared.accountKeyStore.getAccountEntropyPool(tx: tx.asV2Read) else {
                    // This should be impossible; the only times you don't have
                    // a AEP are during registration.
                    owsFail("Can't provision without account entropy pool.")
                }
                rootKey = .accountEntropyPool(accountEntropyPool)
            } else {
                guard let masterKey = DependenciesBridge.shared.accountKeyStore.getMasterKey(tx: tx.asV2Read) else {
                    // This should be impossible; the only times you don't have
                    // a master key are during registration.
                    owsFail("Can't provision without master key.")
                }
                rootKey = .masterKey(masterKey)
            }
            let mrbk = DependenciesBridge.shared.accountKeyStore.getOrGenerateMediaRootBackupKey(tx: tx.asV2Write)
            guard let profileKey = SSKEnvironment.shared.profileManagerRef.localUserProfile(tx: tx)?.profileKey else {
                owsFail("Can't provision without a profile key.")
            }
            return ProvisioningState(
                localIdentifiers: localIdentifiers,
                aciIdentityKeyPair: aciIdentityKeyPair,
                pniIdentityKeyPair: pniIdentityKeyPair,
                areReadReceiptsEnabled: areReadReceiptsEnabled,
                rootKey: rootKey,
                mediaRootBackupKey: mrbk,
                profileKey: profileKey
            )
        }

        let myAci = provisioningState.localIdentifiers.aci
        let myPhoneNumber = provisioningState.localIdentifiers.phoneNumber
        guard let myPni = provisioningState.localIdentifiers.pni else {
            owsFail("Can't provision without a pni.")
        }

        let deviceProvisioner = OWSDeviceProvisioner(
            myAciIdentityKeyPair: provisioningState.aciIdentityKeyPair.identityKeyPair,
            myPniIdentityKeyPair: provisioningState.pniIdentityKeyPair.identityKeyPair,
            theirPublicKey: deviceProvisioningUrl.publicKey,
            theirEphemeralDeviceId: deviceProvisioningUrl.ephemeralDeviceId,
            myAci: myAci,
            myPhoneNumber: myPhoneNumber,
            myPni: myPni,
            profileKey: provisioningState.profileKey.keyData,
            rootKey: provisioningState.rootKey,
            mrbk: provisioningState.mediaRootBackupKey,
            ephemeralBackupKey: ephemeralBackupKey,
            readReceiptsEnabled: provisioningState.areReadReceiptsEnabled,
            provisioningService: DeviceProvisioningServiceImpl(
                networkManager: SSKEnvironment.shared.networkManagerRef,
                schedulers: DependenciesBridge.shared.schedulers
            ),
            schedulers: DependenciesBridge.shared.schedulers
        )

        Task {
            do {
                let tokenId = try await deviceProvisioner.provision()
                Logger.info("Successfully provisioned device.")

                self.delegate?.didFinishLinking(
                    ephemeralBackupKey.map { ($0, tokenId) },
                    from: self
                )
            } catch {
                Logger.error("Failed to provision device with error: \(error)")
                let actionSheet = self.retryActionSheetController(error: error, retryBlock: { [weak self] in
                    self?.provisionWithUrl(deviceProvisioningUrl, shouldLinkNSync: shouldLinkNSync)
                })
                self.safePresent(actionSheet)
            }
        }
    }

    private func retryActionSheetController(error: Error, retryBlock: @escaping () -> Void) -> ActionSheetController {
        switch error {
        case let error as DeviceLimitExceededError:
            let actionSheet = ActionSheetController(
                title: error.errorDescription,
                message: error.recoverySuggestion
            )
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.okButton,
                handler: { [weak self] _ in
                    self?.popToLinkedDeviceList()
                }
            ))
            return actionSheet

        default:
            let actionSheet = ActionSheetController(
                title: OWSLocalizedString("LINKING_DEVICE_FAILED_TITLE", comment: "Alert Title"),
                message: error.userErrorDescription
            )
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.retryButton,
                style: .default,
                handler: { action in retryBlock() }
            ))
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.cancelButton,
                style: .cancel,
                handler: { [weak self] action in
                    DispatchQueue.main.async { self?.dismiss(animated: true) }
                }
            ))
            return actionSheet
        }
    }

    func popToLinkedDeviceList(_ completion: (() -> Void)? = nil) {
        dismissEducationSheetIfNecessary { [weak navigationController] in
            navigationController?.popViewController(animated: true)
            // The method for adding a completion handler to popViewController in
            // UIViewController+SignalUI doesn't play well with UIHostingController
            navigationController?.transitionCoordinator?.animate(alongsideTransition: nil) { _ in
                UIViewController.attemptRotationToDeviceOrientation()
                completion?()
            }
        }
    }

    #if TESTABLE_BUILD
    @objc
    private func manuallyEnterLinkURL() {
        let alertController = UIAlertController(
            title: LocalizationNotNeeded("Manually enter linking code."),
            message: LocalizationNotNeeded("Copy the URL represented by the QR code into the field below."),
            preferredStyle: .alert
        )
        alertController.addTextField()
        alertController.addAction(UIAlertAction(
            title: CommonStrings.okayButton,
            style: .default,
            handler: { _ in
                guard let qrCodeString = alertController.textFields?.first?.text else { return }
                self.qrCodeScanViewScanned(
                    qrCodeData: nil,
                    qrCodeString: qrCodeString
                )
            }
        ))
        alertController.addAction(UIAlertAction(
            title: CommonStrings.cancelButton,
            style: .cancel
        ))
        safePresent(alertController)
    }
    #endif
}

extension LinkDeviceViewController: QRCodeScanOrPickDelegate {

    @discardableResult
    func qrCodeScanViewScanned(
        qrCodeData: Data?,
        qrCodeString: String?
    ) -> QRCodeScanOutcome {
        AssertIsOnMainThread()

        guard let qrCodeString else {
            // Only accept QR codes with a valid string payload.
            return .continueScanning
        }

        guard let url = DeviceProvisioningURL(urlString: qrCodeString) else {
            Logger.error("Unable to parse provisioning params from QRCode: \(qrCodeString)")

            let title = NSLocalizedString("LINK_DEVICE_INVALID_CODE_TITLE", comment: "report an invalid linking code")
            let body = NSLocalizedString("LINK_DEVICE_INVALID_CODE_BODY", comment: "report an invalid linking code")

            let actionSheet = ActionSheetController(title: title, message: body)
            actionSheet.addAction(ActionSheetAction(
                title: CommonStrings.cancelButton,
                style: .cancel,
                handler: { _ in
                    DispatchQueue.main.async {
                        self.popToLinkedDeviceList()
                    }
                }
            ))
            actionSheet.addAction(ActionSheetAction(
                title: NSLocalizedString("LINK_DEVICE_RESTART", comment: "attempt another linking"),
                style: .default,
                handler: { _ in
                    self.qrCodeScanViewController.tryToStartScanning()
                }
            ))
            safePresent(actionSheet)

            return .stopScanning
        }

        confirmProvisioningWithUrl(url)

        return .stopScanning
    }

    func qrCodeScanViewDismiss(_ qrCodeScanViewController: SignalUI.QRCodeScanViewController) {
        AssertIsOnMainThread()
        popToLinkedDeviceList()
    }
}

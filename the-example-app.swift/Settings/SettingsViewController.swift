

import Foundation
import UIKit
import Contentful
import Interstellar

class SettingsViewController: UITableViewController, TabBarTabViewController, UITextFieldDelegate, CustomNavigable {

    var tabItem: UITabBarItem {
        return UITabBarItem(title: "settingsLabel".localized(contentfulService: services.contentful),
                            image: UIImage(named: "tabbar-icon-settings"),
                            selectedImage: nil)
    }
    
    var services: Services!

    static func new(services: Services) -> SettingsViewController {
        let settings = UIStoryboard.init(name: "SettingsViewController", bundle: nil).instantiateInitialViewController() as! SettingsViewController
        settings.services = services
        return settings
    }

    // MARK: CustomNavigable

    var hasCustomToolbar: Bool {
        return false
    }

    var prefersLargeTitles: Bool {
        return true
    }

    var onAppear: (() -> Void)?

    // MARK: UIViewController

    override func loadView() {
        super.loadView()
        tableView.rowHeight = UITableViewAutomaticDimension
        tableView.sectionHeaderHeight = UITableViewAutomaticDimension
        tableView.estimatedRowHeight = 60
        tableView.separatorStyle = .none

        tableView.registerNibFor(ToggleTableViewCell.self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(self, selector: #selector(SettingsViewController.changeTextFieldText(_:)), name: .UITextFieldTextDidChange, object: nil)

        view.backgroundColor = UIColor(red: 0.94, green: 0.94, blue: 0.96, alpha:1.0)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Connect", style: .plain, target: self, action: #selector(SettingsViewController.didTapSaveSettings(_:)))

        addObservations()

        services.contentfulStateMachine.addTransitionObservation { [unowned self] _ in
            DispatchQueue.main.async {
                self.resetErrors()
            }
        }
        services.contentfulStateMachine.addTransitionObservationAndObserveInitialState { [unowned self] _ in
            DispatchQueue.main.async {
                if self.isShowingError == false {
                    // If we directly injected an error, we don't want to override what's in the fields.
                    self.updateFormFieldsWithCurrentSessionInfo()
                }
                self.updateOtherViewsCurrentSessionInfo()
                self.removeObservations()
                self.addObservations()
            }
        }
        for textField in [spaceIdTextField, deliveryAccessTokenTextField, previewAccessTokenTextField] {
            textField?.delegate = self
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        onAppear?()
        onAppear = nil

        Analytics.shared.logViewedRoute("/settings", spaceId: services.contentful.spaceId)
    }

    // State change reactions.
    var stateObservationToken: String?

    func removeObservations() {
        if let token = stateObservationToken {
            services.contentful.stateMachine.stopObserving(token: token)
            stateObservationToken = nil
        }
    }

    func addObservations() {
        // Update all text labels.
        stateObservationToken = services.contentful.stateMachine.addTransitionObservationAndObserveInitialState { [unowned self] _ in
            DispatchQueue.main.async {
                self.title = "settingsLabel".localized(contentfulService: self.services.contentful)

                self.localeDescriptionLabel.text = "localeQuestion".localized(contentfulService: self.services.contentful)
                self.apiDescriptionLabel.text = "apiSwitcherHelp".localized(contentfulService: self.services.contentful)

                self.connectedToSpaceLabel.text = "connectedToSpaceLabel".localized(contentfulService: self.services.contentful)
                self.overrideConfigLabel.text = "overrideConfigLabel".localized(contentfulService: self.services.contentful)

                self.spaceIdDescriptionLabel.text = "spaceIdLabel".localized(contentfulService: self.services.contentful)
                self.deliveryAccessTokenDescriptionLabel.text = "cdaAccessTokenLabel".localized(contentfulService: self.services.contentful)
                self.previewAccessTokenDescriptionLabel.text = "cpaAccessTokenLabel".localized(contentfulService: self.services.contentful)
                self.credentialsHelpTextLabel.text = "settingsIntroLabel".localized(contentfulService: self.services.contentful)

                self.enableEditorialFeaturesLabel.text = "enableEditorialFeaturesLabel".localized(contentfulService: self.services.contentful)
                self.enableEditorialFeaturesHelpTextLabel.text = "enableEditorialFeaturesHelpText".localized(contentfulService: self.services.contentful)
                self.tableView.reloadData()
            }
        }
    }

    func updateFormFieldsWithCurrentSessionInfo() {
        // Populate current credentials in text fields.
        spaceIdTextField.text = services.contentful.spaceId
        deliveryAccessTokenTextField.text = services.contentful.deliveryAccessToken
        previewAccessTokenTextField.text = services.contentful.previewAccessToken
    }

    func updateOtherViewsCurrentSessionInfo() {
        editorialFeaturesSwitch.isOn = services.contentful.editorialFeaturesAreEnabled

        let _ = services.contentful.client.fetchSpace().then { [unowned self] space in
            DispatchQueue.main.async {
                self.currentlyConnectedSpaceLabel.text = space.name + " (" + space.id + ")"
            }
        }
    }

    public var isShowingError: Bool = false

    func validationErrorMessageFor(textField: UITextField) -> String? {
        if textField.text == nil || textField.text!.isEmpty {
            return "fieldIsRequiredLabel".localized(contentfulService: services.contentful)
        }
        return nil
    }

    @objc func didTapSaveSettings(_ sender: Any) {
        dismissKeyboard()

        let loadingOverlay = UIView.loadingOverlay(frame: navigationController!.view.frame)

        DispatchQueue.main.async { [unowned self] in
            self.navigationController?.view.addSubview(loadingOverlay)
            self.navigationController?.view.setNeedsLayout()
            self.navigationController?.view.layoutIfNeeded()
        }

        let dismissOverlay = {
            DispatchQueue.main.async { [unowned self] in
                loadingOverlay.removeFromSuperview()
                if self.isShowingError {
                    self.tableView.scrollRectToVisible(CGRect(x: 0, y: 0, width: 1, height: 1), animated: true)
                }
            }
        }

        var errorMessages = [CredentialsTester.ErrorKey: String]()
        errorMessages[.spaceId] = validationErrorMessageFor(textField: spaceIdTextField)
        errorMessages[.deliveryAccessToken] = validationErrorMessageFor(textField: deliveryAccessTokenTextField)
        errorMessages[.previewAccessToken] = validationErrorMessageFor(textField: previewAccessTokenTextField)

        guard errorMessages.count == 0 else {
            dismissOverlay()
            showErrorHeader(credentialsError: CredentialsTester.Error(errors: errorMessages))
            return
        }

        if let newSpaceId = self.spaceIdTextField.text,
            let newDeliveryAccessToken = self.deliveryAccessTokenTextField.text,
            let newPreviewAccessToken = self.previewAccessTokenTextField.text {

            DispatchQueue.global(qos: .background).async { [unowned self] in

                let newCredentials = ContentfulCredentials(spaceId: newSpaceId,
                                                           deliveryAPIAccessToken: newDeliveryAccessToken,
                                                           previewAPIAccessToken: newPreviewAccessToken)

                let testResults = CredentialsTester.testCredentials(credentials: newCredentials, services: self.services)

                dismissOverlay()

                DispatchQueue.main.async {
                    switch testResults {
                    case .success(let newContentfulService):
                        self.services.contentful = newContentfulService

                        self.services.session.spaceCredentials = newCredentials
                        self.services.session.persistCredentials()

                        dismissOverlay()

                        let alertController = AlertController.credentialSuccess(credentials: newCredentials)
                        self.navigationController?.present(alertController, animated: true, completion: nil)

                    case .error(let error):
                        self.isShowingError = true

                        DispatchQueue.main.async {
                            self.showErrorHeader(credentialsError: error as! CredentialsTester.Error)
                        }
                    }
                }
            }
        }
    }

    func resetErrors() {
        DispatchQueue.main.async { [unowned self] in
            self.isShowingError = false
            self.tableView.beginUpdates()
            self.tableView.tableHeaderView = nil
            self.tableView.endUpdates()
        }
    }

    public func showErrorHeader(credentialsError: CredentialsTester.Error) {
        DispatchQueue.main.async {

            var errorMessages = [String]()
            for (_, errorMessage) in credentialsError.errorMessages {
                errorMessages.append(errorMessage)
            }

            let settingsErrorHeader = UINib(nibName: "SettingsErrorHeader", bundle: nil).instantiate(withOwner: nil, options: nil)[0] as! SettingsErrorHeader
            settingsErrorHeader.configure(errorMessages: errorMessages)

            self.tableView.beginUpdates()
            self.tableView.tableHeaderView = settingsErrorHeader
            self.tableView.layoutTableHeaderView()
            self.tableView.endUpdates()
        }
    }

    public func populateCredentialFielsWithValueInError(credentialsError: CredentialsTester.Error) {
        let callback = {
            DispatchQueue.main.async {
                self.spaceIdTextField.text = credentialsError.spaceId
                self.deliveryAccessTokenTextField.text = credentialsError.deliveryAccessToken
                self.previewAccessTokenTextField.text = credentialsError.previewAccessToken
            }
        }
        // Check if view is already visible.
        if let _ = tableView {
            callback()
        } else {
            // If the tableView hasn't been loaded yet, let's add a callback to execute later.
            onAppear = callback
        }
    }

    let toggleCellFactory = TableViewCellFactory<ToggleTableViewCell>()

    // Model.
    let apis: [ContentfulService.State.API] = [.delivery, .preview]

    static let localesSectionIndex = 2
    static let apisSectionIndex = 3

    // MARK: UITableViewDelegate

    @IBOutlet weak var connectedSpaceCell: UITableViewCell!

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let cell = tableView.cellForRow(at: indexPath)
        if cell === connectedSpaceCell {
            let connectedSpaceViewController = ConnectedSpaceViewController.new(services: services)
            navigationController?.pushViewController(connectedSpaceViewController, animated: true)
            return
        }
        guard (indexPath.section == SettingsViewController.localesSectionIndex ||
            indexPath.section == SettingsViewController.apisSectionIndex) &&
            indexPath.row != 0 else {
            return
        }

        let dataSourceIndex = indexPath.row - 1
        switch indexPath.section {
        case SettingsViewController.localesSectionIndex:
            services.contentful.stateMachine.state.locale = services.contentful.locales[dataSourceIndex]
            tableView.reloadData()
        case SettingsViewController.apisSectionIndex:
            services.contentful.stateMachine.state.api = apis[dataSourceIndex]
            tableView.reloadData()
        default: break
        }
    }

    // The following 3 datasource method overrides are to enable proper handling of dynamically inserting
    // extra locale cells into what is otherwise a static table view.
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == SettingsViewController.localesSectionIndex {
            return services.contentful.locales.count + 1
        }
        return super.tableView(tableView, numberOfRowsInSection: section)
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section != SettingsViewController.localesSectionIndex {
            return super.tableView(tableView, heightForRowAt: indexPath)
        }
        if indexPath.row == 0 {
            return super.tableView(tableView, heightForRowAt: indexPath)
        }
        return 44
    }

    override func tableView(_ tableView: UITableView, indentationLevelForRowAt indexPath: IndexPath) -> Int {
        if indexPath.section != SettingsViewController.localesSectionIndex {
            return super.tableView(tableView, indentationLevelForRowAt: indexPath)
        }
        if indexPath.row == 0 {
            return super.tableView(tableView, indentationLevelForRowAt: indexPath)
        }
        return 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section != SettingsViewController.localesSectionIndex && indexPath.section != SettingsViewController.apisSectionIndex {
            return super.tableView(tableView, cellForRowAt: indexPath)
        }

        if indexPath.row == 0 {
            return super.tableView(tableView, cellForRowAt: indexPath)
        }

        let cell: UITableViewCell
        let dataSourceIndex = indexPath.row - 1
        switch indexPath.section {
        case SettingsViewController.localesSectionIndex:

            let isCurrentLocale = services.contentful.stateMachine.state.locale == services.contentful.locales[dataSourceIndex]
            let model = ToggleTableViewCell.Model(title: services.contentful.locales[dataSourceIndex].name, isSelected: isCurrentLocale)
            cell = toggleCellFactory.cell(for: model, in: tableView, at: indexPath)
        case SettingsViewController.apisSectionIndex:
            let isCurrentAPI = services.contentful.stateMachine.state.api == apis[dataSourceIndex]
            let model = ToggleTableViewCell.Model(title: apis[dataSourceIndex].title(), isSelected: isCurrentAPI)
            cell = toggleCellFactory.cell(for: model, in: tableView, at: indexPath)
        default:
            fatalError()
        }
        return cell
    }

    // MARK: Interface Builder

    @IBOutlet weak var localeDescriptionLabel: UILabel!
    @IBOutlet weak var apiDescriptionLabel: UILabel!
    @IBOutlet weak var overrideConfigLabel: UILabel!
    @IBOutlet weak var connectedToSpaceLabel: UILabel!
    @IBOutlet weak var currentlyConnectedSpaceLabel: UILabel!

    @IBOutlet weak var spaceIdDescriptionLabel: UILabel!
    @IBOutlet weak var deliveryAccessTokenDescriptionLabel: UILabel!

    @IBOutlet weak var previewAccessTokenDescriptionLabel: UILabel!

    @IBOutlet weak var spaceIdTextField: CredentialTextField! {
        didSet {
            spaceIdTextField.accessibilityLabel = "Space ID field"
        }
    }

    @IBOutlet weak var deliveryAccessTokenTextField: CredentialTextField! {
        didSet {
            deliveryAccessTokenTextField.accessibilityLabel = "Content Delivery API access token field"
        }
    }

    @IBOutlet weak var previewAccessTokenTextField: CredentialTextField! {
        didSet {
            previewAccessTokenTextField.accessibilityLabel = "Content Preview API access token field"
        }
    }


    @IBOutlet weak var credentialsHelpTextLabel: UILabel!

    @IBOutlet weak var editorialFeaturesSwitch: UISwitch!
    @IBAction func didToggleEditorialFeatures(_ sender: Any) {
        services.contentful.enableEditorialFeatures(editorialFeaturesSwitch.isOn)
    }

    @IBOutlet weak var enableEditorialFeaturesLabel: UILabel!
    @IBOutlet weak var enableEditorialFeaturesHelpTextLabel: UILabel!

    @objc func dismissKeyboard() {
        tableView.endEditing(true)
    }

    // MARK: UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == spaceIdTextField {
            spaceIdTextField.resignFirstResponder()
            deliveryAccessTokenTextField.becomeFirstResponder()
        } else if textField == deliveryAccessTokenTextField {
            deliveryAccessTokenTextField.resignFirstResponder()
            previewAccessTokenTextField.becomeFirstResponder()
        } else if textField == previewAccessTokenTextField {
            previewAccessTokenTextField.resignFirstResponder()

            // Attempt to save.
        }

        return true
    }

    weak var keyboardDoneButton: UIBarButtonItem?

    func textFieldDidBeginEditing(_ textField: UITextField) {

        let toolbar = UIToolbar(frame: CGRect(x: 0.0, y: 0.0, width: view.frame.size.width, height: 50.0))

        toolbar.barStyle = UIBarStyle.default
        let keyboardDoneButton = UIBarButtonItem(title: "Connect", style: .plain, target: self, action: #selector(SettingsViewController.didTapSaveSettings(_:)))
        toolbar.items = [
            UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(SettingsViewController.dismissKeyboard)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            keyboardDoneButton
        ]
        toolbar.sizeToFit()
        textField.inputAccessoryView = toolbar

        if textField == previewAccessTokenTextField {
            textField.returnKeyType = .done
        } else {
            textField.returnKeyType = .next
        }
        textField.becomeFirstResponder()
        self.keyboardDoneButton = keyboardDoneButton
        updateButtonStates()
    }

    func textFieldDidEndEditing(_ textField: UITextField, reason: UITextFieldDidEndEditingReason) {
        textField.resignFirstResponder()
    }

    @objc func changeTextFieldText(_ sender: Any) {
        updateButtonStates()
    }

    func updateButtonStates() {
        let canAttemptSave = spaceIdTextField.text?.isEmpty == false &&
            deliveryAccessTokenTextField.text?.isEmpty == false &&
            previewAccessTokenTextField.text?.isEmpty == false

        navigationItem.leftBarButtonItem?.isEnabled = !canAttemptSave
        keyboardDoneButton?.isEnabled = canAttemptSave
        navigationItem.rightBarButtonItem?.isEnabled = canAttemptSave
        navigationItem.rightBarButtonItem?.isEnabled = canAttemptSave
        previewAccessTokenTextField.enablesReturnKeyAutomatically = !canAttemptSave
    }
}


extension UITableView {

    func layoutTableHeaderView() {

        guard let headerView = tableHeaderView else { return }
        headerView.translatesAutoresizingMaskIntoConstraints = false

        headerView.setNeedsLayout()
        headerView.layoutIfNeeded()

        let headerSize = headerView.systemLayoutSizeFitting(UILayoutFittingCompressedSize)
        let height = headerSize.height
        var frame = headerView.frame

        frame.size.height = height
        headerView.frame = frame

        headerView.translatesAutoresizingMaskIntoConstraints = true
        tableHeaderView = headerView
    }
}

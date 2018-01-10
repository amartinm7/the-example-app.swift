
import Foundation
import Contentful
import Interstellar

enum ResourceState {
    case upToDate
    case draft
    case pendingChanges
}

protocol StatefulResource: class {
    var state: ResourceState { get set }
}

class ContentfulService {

    /// The client used to pull data from the Content Delivery API.
    public let deliveryClient: Client

    /// The client used to pull data from the Content Preview API.
    public let previewClient: Client

    public let deliveryAccessToken: String
    public let previewAccessToken: String
    public let spaceId: String

    public func toggleAPI() {
        switch apiStateMachine.state {
        case .delivery(let editiorialFeatures):
            apiStateMachine.state = .preview(editorialFeatureEnabled: editiorialFeatures)
        case .preview(let editiorialFeatures):
            apiStateMachine.state = .delivery(editorialFeatureEnabled: editiorialFeatures)
        }
    }

    public func toggleLocale() {
        switch localeStateMachine.state {
        case .americanEnglish:
            localeStateMachine.state = .german
        case .german:
            localeStateMachine.state = .americanEnglish
        }
    }

    public func enableEditorialFeatures(_ shouldEnable: Bool) {
        session.persistEditorialFeatureState(isOn: shouldEnable)
        switch apiStateMachine.state {
        case .delivery:
            apiStateMachine.state = .delivery(editorialFeatureEnabled: shouldEnable)
        case .preview:
            apiStateMachine.state = .preview(editorialFeatureEnabled: shouldEnable)
        }
    }

    public var editorialFeaturesAreEnabled: Bool {
        switch apiStateMachine.state {
        case .delivery(let editiorialFeaturesEnabled):
            return editiorialFeaturesEnabled
        case .preview(let editiorialFeaturesEnabled):
            return editiorialFeaturesEnabled
        }
    }

    public let apiStateMachine: StateMachine<ContentfulService.State>

    public let localeStateMachine: StateMachine<ContentfulService.Locale>

    var currentLocaleCode: LocaleCode {
        return localeStateMachine.state.code()
    }

    public func resolveStateIfNecessary<T>(for resource: T, then completion: @escaping (Result<T>, T?) -> Void) where T: ResourceQueryable & EntryDecodable & StatefulResource {

        switch apiStateMachine.state {

        case .preview(let editorialFeatureEnabled) where editorialFeatureEnabled == true:
            let query = QueryOn<T>.where(sys: .id, .equals(resource.sys.id))

            deliveryClient.fetchMappedEntries(matching: query) { [unowned self] deliveryResult in
                if let error = deliveryResult.error {
                    completion(Result.error(error), nil)
                }

                let statefulPreviewResource = self.inferStateFromDiffs(previewResource: resource, deliveryResult: deliveryResult)
                completion(Result.success(statefulPreviewResource), deliveryResult.value!.items.first!)
            }
        default:
            // If not connected to the Preview API with editorial features enabled, continue execution without
            // additional state resolution.
            break
        }
    }

    public func inferStateFromLinkedModuleDiffs<T>(statefulRootAndModules: (T, [Module]),
                                                   deliveryModules: [Module]) -> T where T: StatefulResource {

        let (previewRoot, previewModules) = statefulRootAndModules
        let deliveryModules = deliveryModules

        if previewRoot.state != .upToDate {
            return previewRoot
        }
        if deliveryModules.count != previewModules.count {
            previewRoot.state = .pendingChanges
            return previewRoot
        }

        for index in 0..<deliveryModules.count {
            if previewModules[index].sys.id != deliveryModules[index].sys.id {
                // The content editor has changed the ordering of the modules.
                previewRoot.state = .pendingChanges
                return previewRoot
            }
            if previewModules[index].sys.updatedAt != deliveryModules[index].sys.updatedAt {
                // Check if there are pending changes to the content of the resource itself.
                previewRoot.state = .pendingChanges
            }
        }

        return previewRoot
    }

    private func inferStateFromDiffs<T>(previewResource: T, deliveryResult: Result<MappedArrayResponse<T>>) -> T where T: StatefulResource {

        if let deliveryResource = deliveryResult.value?.items.first  {
            if deliveryResource.sys.updatedAt != previewResource.sys.updatedAt {
                previewResource.state = .pendingChanges
            }
        } else {
            // The Resource is available on     the Preview API but not the Delivery API, which means it's in draft.
            previewResource.state = .draft
        }
        return previewResource
    }

    public enum Locale {
        case americanEnglish
        case german

        func code() -> LocaleCode {
            // TODO: use locales from space.
            switch self {
            case .americanEnglish:
                return "en-US"
            case .german:
                return "de-DE"
            }
        }

        func barButtonTitle() -> String {
            switch self {
            case .americanEnglish:
                return "English"
            case .german:
                return "German"
            }
        }
    }

    func localeBarButtonTitle() -> String {
        return localeStateMachine.state.barButtonTitle()
    }

    func apiBarButtonTitle() -> String {
        return apiStateMachine.state.barButtonTitle()
    }

    public enum State {
        case delivery(editorialFeatureEnabled: Bool)
        case preview(editorialFeatureEnabled: Bool)

        func barButtonTitle() -> String {
            switch self {
            case .delivery:
                return "API: Delivery"
            case .preview:
                return "API: Preview"
            }
        }

    }

    public var client: Client {
        switch apiStateMachine.state {
        case .delivery: return deliveryClient
        case .preview: return previewClient
        }
    }

    let session: Session

    init(session: Session, credentials: ContentfulCredentials, state: State) {
        self.session = session
        self.spaceId = credentials.spaceId
        self.deliveryAccessToken = credentials.deliveryAPIAccessToken
        self.previewAccessToken = credentials.previewAPIAccessToken
        
        self.deliveryClient = Client(spaceId: credentials.spaceId,
                                     accessToken: credentials.deliveryAPIAccessToken,
                                     contentTypeClasses: Services.contentTypeClasses)

        // This time, we configure the client to pull content from the Content Preview API.
        var previewConfiguration = ClientConfiguration()
        previewConfiguration.previewMode = true
        self.previewClient = Client(spaceId: credentials.spaceId,
                                    accessToken: credentials.previewAPIAccessToken,
                                    clientConfiguration: previewConfiguration,
                                    contentTypeClasses: Services.contentTypeClasses)


        self.apiStateMachine = StateMachine<State>(initialState: state)
        self.localeStateMachine = StateMachine<Locale>(initialState: .americanEnglish)

    }
}

class Services {

    var session: Session
    
    var contentful: ContentfulService

    static var contentTypeClasses: [EntryDecodable.Type] = [
        HomeLayout.self,
        Course.self,
        HighlightedCourse.self,
        Lesson.self,
        LessonCopy.self,
        LessonImage.self,
        LessonSnippets.self,
        Category.self
    ]

    init(session: Session) {
        self.session = session
        let spaceCredentials = session.spaceCredentials
        contentful = ContentfulService(session: session,
                                       credentials: spaceCredentials,
                                       state: .delivery(editorialFeatureEnabled: session.areEditorialFeaturesEnabled()))
    }
}

extension ContentfulService.State: Equatable {}

func ==(lhs: ContentfulService.State, rhs: ContentfulService.State) -> Bool {
    switch (lhs, rhs) {
    case (.delivery(let editorialLHS), .delivery(let editorialRHS)):
        return editorialLHS == editorialRHS
    case (.preview(let editorialLHS), .preview(let editorialRHS)):
        return editorialLHS == editorialRHS
    default:
        return false
    }
}

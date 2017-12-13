        
import Foundation
import UIKit
import Contentful
import Interstellar

class CoursesViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, CategorySelectorDelegate {

    let services: Services

    /**
     * The detail view controller for a course that is currenlty pushed onto the navigation stack.
     * This property is declared as weak so that when the navigaton controller pops the course view controller
     * it will not be retained here.
     */
    weak var courseViewController: CourseViewController?

    // Data model for this view controller.
    var courses: [Course]?

    let coursesSectionIndex: Int = 1

    var categories: [Category]?

    var selectedCategory: Category?

    // We must retain the data source.
    var tableViewDataSource: UITableViewDataSource? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.tableView.dataSource = self!.tableViewDataSource
                self?.tableView.reloadData()
            }
        }
    }

    // Table view and cell rendering.
    var tableView: UITableView!
    let coursesCellFactory = TableViewCellFactory<CourseTableViewCell>()
    let categorySelectorCellFactory = TableViewCellFactory<CategorySelectorTableViewCell>()

    // Contentful queries.
    var categoriesQuery: QueryOn<Category> {
        let localeCode = services.contentful.currentLocaleCode
        return QueryOn<Category>.localizeResults(withLocaleCode: localeCode)
    }

    var coursesQuery: QueryOn<Course> {
        let localeCode = services.contentful.currentLocaleCode
        let query = QueryOn<Course>.include(2).localizeResults(withLocaleCode: localeCode)
        try! query.order(by: Ordering(sys: .createdAt, inReverse: true))
        if let selectedCategory = selectedCategory {
            // TODO: Add a method to the SDK for this.
            query.where(valueAtKeyPath: "fields.categories.sys.id", .equals(selectedCategory.id))
        }
        return query
    }

    // Requests.
    var coursesRequest: URLSessionTask?
    var categoriesRequest: URLSessionTask?

    init(services: Services) {
        self.services = services
        super.init(nibName: nil, bundle: nil)
        title = "Courses"
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateAPI(_ observation: StateMachine<Contentful.State>.Transition) {
        fetchCategoriesFromContentful()
    }

    func updateLocale(_ observation: StateMachine<Contentful.Locale>.Transition) {
        fetchCategoriesFromContentful()
    }

    func fetchCategoriesFromContentful() {
        tableViewDataSource = LoadingTableViewDataSource()

        // Cancel the previous request before making a new one.
        categoriesRequest?.cancel()
        categoriesRequest = services.contentful.client.fetchMappedEntries(matching: categoriesQuery) { [weak self] result in
            self?.categoriesRequest = nil
            switch result {
            case .success(let arrayResponse):
                self?.categories = arrayResponse.items
                self?.tableViewDataSource = self
                self?.fetchCoursesFromContentful()

            case .error(let error):
                // TODO:
                print(error)
                self?.tableViewDataSource = ErrorTableViewDataSource(error: error)
            }
        }
    }

    func fetchCoursesFromContentful() {
        // Show loading state by settting the data source to nil.
        reloadCoursesSection(courses: nil)

        // Cancel the previous request before making a new one.
        coursesRequest?.cancel()
        coursesRequest = services.contentful.client.fetchMappedEntries(matching: coursesQuery) { [weak self] result in
            self?.coursesRequest = nil
            switch result {
            case .success(let arrayResponse):
                self?.reloadCoursesSection(courses: arrayResponse.items)
                self?.updatePushedCourseViewController()
                self?.resolveStatesOnCourses()

            case .error(let error):
                // TODO:
                print(error)
                self?.tableViewDataSource = ErrorTableViewDataSource(error: error)
            }
        }
    }

    func resolveStatesOnCourses() {
        guard let courses = self.courses else { return }

        for course in courses {
            services.contentful.resolveStateIfNecessary(for: course) { [weak self] (result: Result<Course>, _) in
                guard let statefulCourse = result.value else { return }
                if let index = courses.index(where: { $0.id == course.id }) {
                    self?.courses?[index] = statefulCourse

                    DispatchQueue.main.async {
                        guard let strongSelf = self else { return }
                        let indexPath = IndexPath(row: index, section: strongSelf.coursesSectionIndex)
                        strongSelf.tableView.reloadRows(at: [indexPath], with: .middle)
                    }
                }
                self?.updatePushedCourseViewController()
            }
        }
    }

    func updatePushedCourseViewController() {
        if let currentCourse = courseViewController?.course, let course = courses?.filter({ $0.id == currentCourse.id }).first {
            courseViewController?.course = course
        }
    }

    func reloadCoursesSection(courses: [Course]?) {
        // Guard against crash for updating a table view section that is not currently being rendered.
        guard categoriesRequest == nil else { return }

        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.tableView.numberOfSections > strongSelf.coursesSectionIndex else { return }
            strongSelf.tableView.beginUpdates()

            // Update the data source here.
            self?.courses = courses

            strongSelf.tableView.reloadSections(IndexSet(integer: strongSelf.coursesSectionIndex), with: .bottom)
            strongSelf.tableView.endUpdates()
        }
    }


    var apiStateObservationToken: String?

    var localeStateObservationToken: String?

    func addStateObservations() {
        apiStateObservationToken = services.contentful.apiStateMachine.addTransitionObservation(updateAPI(_:))
        localeStateObservationToken = services.contentful.localeStateMachine.addTransitionObservationAndObserveInitialState(updateLocale(_:))
    }

    func removeStateObservations() {
        if let token = apiStateObservationToken {
            services.contentful.apiStateMachine.stopObserving(token: token)
        }
        if let token = localeStateObservationToken {
            services.contentful.localeStateMachine.stopObserving(token: token)
        }
    }

    // MARK: UIViewController

    override func loadView() {
        tableView = UITableView(frame: .zero)

        tableView.registerNibFor(CategorySelectorTableViewCell.self)
        tableView.registerNibFor(CourseTableViewCell.self)
        tableView.registerNibFor(LoadingTableViewCell.self)
        tableView.register(ErrorTableViewCell.self)

        view = tableView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.delegate = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        addStateObservations()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        removeStateObservations()
    }

    // MARK: CategorySelectorDelegate

    func didSelectCategory(_ category: Category?) {
        guard selectedCategory != category else { return }

        selectedCategory = category
        fetchCoursesFromContentful()
    }

    // MARK: UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:                     return 1
        // The section that displays courses has it's own loading state, so return 1 if there are no courses.
        case coursesSectionIndex:   return courses?.count ?? 1
        default:                    return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        switch indexPath.section {
        case 0:
            let cellModel = CategorySelectorTableViewCell.Model(categories: categories, delegate: self, selectedCategory: selectedCategory)
            cell = categorySelectorCellFactory.cell(for: cellModel, in: tableView, at: indexPath)
        case coursesSectionIndex:
            if let courses = courses {
                let course = courses[indexPath.item]
                cell = coursesCellFactory.cell(for: course, in: tableView, at: indexPath)
            } else {
                // Return a loading cell.
                cell = TableViewCellFactory<LoadingTableViewCell>().cell(for: nil, in: tableView, at: indexPath)
            }

        default: fatalError("TODO")
        }
        return cell
    }

    // MARK: UITablieViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.section == coursesSectionIndex else { return }
        
        guard let course = courses?[indexPath.item] else {
            fatalError("TODO")
        }
        let courseViewController = CourseViewController(course: course, services: services)
        navigationController?.pushViewController(courseViewController, animated: true)
        self.courseViewController = courseViewController
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch indexPath.section {
        case 0:     return 50
        // Enable table view cells to be sized dynamically based on inner content.
        default:    return UITableViewAutomaticDimension
        }
    }
}

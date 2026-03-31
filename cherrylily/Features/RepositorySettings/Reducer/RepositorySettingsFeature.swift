import ComposableArchitecture
import Foundation

@Reducer
struct RepositorySettingsFeature {
  @ObservableState
  struct State: Equatable {
    var rootURL: URL
    var settings: RepositorySettings
    var globalDefaultWorktreeBaseDirectoryPath: String?
    var globalCopyIgnoredOnWorktreeCreate: Bool = false
    var globalCopyUntrackedOnWorktreeCreate: Bool = false
    var globalPullRequestMergeStrategy: PullRequestMergeStrategy = .merge
    var isBareRepository = false
    var branchOptions: [String] = []
    var defaultWorktreeBaseRef = "origin/main"
    var isBranchDataLoaded = false

    var exampleWorktreePath: String {
      CherryLilyPaths.exampleWorktreePath(
        for: rootURL,
        globalDefaultPath: globalDefaultWorktreeBaseDirectoryPath,
        repositoryOverridePath: settings.worktreeBaseDirectoryPath,
        branchName: "**/*"
      )
    }
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(
      RepositorySettings,
      isBareRepository: Bool,
      globalDefaultWorktreeBaseDirectoryPath: String?,
      globalCopyIgnoredOnWorktreeCreate: Bool,
      globalCopyUntrackedOnWorktreeCreate: Bool,
      globalPullRequestMergeStrategy: PullRequestMergeStrategy
    )
    case branchDataLoaded([String], defaultBaseRef: String)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(URL)
  }

  @Dependency(GitClientDependency.self) private var gitClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        let rootURL = state.rootURL
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        @Shared(.settingsFile) var settingsFile
        let settings = repositorySettings
        let global = settingsFile.global
        let globalDefaultWorktreeBaseDirectoryPath = global.defaultWorktreeBaseDirectoryPath
        let globalCopyIgnored = global.copyIgnoredOnWorktreeCreate
        let globalCopyUntracked = global.copyUntrackedOnWorktreeCreate
        let globalMergeStrategy = global.pullRequestMergeStrategy
        let gitClient = gitClient
        return .run { send in
          let isBareRepository = (try? await gitClient.isBareRepository(rootURL)) ?? false
          await send(
            .settingsLoaded(
              settings,
              isBareRepository: isBareRepository,
              globalDefaultWorktreeBaseDirectoryPath: globalDefaultWorktreeBaseDirectoryPath,
              globalCopyIgnoredOnWorktreeCreate: globalCopyIgnored,
              globalCopyUntrackedOnWorktreeCreate: globalCopyUntracked,
              globalPullRequestMergeStrategy: globalMergeStrategy
            )
          )
          let branches: [String]
          do {
            branches = try await gitClient.branchRefs(rootURL)
          } catch {
            let rootPath = rootURL.path(percentEncoded: false)
            SupaLogger("Settings").warning(
              "Branch refs failed for \(rootPath): \(error.localizedDescription)"
            )
            branches = []
          }
          let defaultBaseRef = await gitClient.automaticWorktreeBaseRef(rootURL) ?? "HEAD"
          await send(.branchDataLoaded(branches, defaultBaseRef: defaultBaseRef))
        }

      case .settingsLoaded(
        let settings,
        let isBareRepository,
        let globalDefaultWorktreeBaseDirectoryPath,
        let globalCopyIgnoredOnWorktreeCreate,
        let globalCopyUntrackedOnWorktreeCreate,
        let globalPullRequestMergeStrategy
      ):
        var updatedSettings = settings
        updatedSettings.worktreeBaseDirectoryPath = CherryLilyPaths.normalizedWorktreeBaseDirectoryPath(
          updatedSettings.worktreeBaseDirectoryPath,
          repositoryRootURL: state.rootURL
        )
        if isBareRepository {
          updatedSettings.copyIgnoredOnWorktreeCreate = nil
          updatedSettings.copyUntrackedOnWorktreeCreate = nil
        }
        state.settings = updatedSettings
        state.globalDefaultWorktreeBaseDirectoryPath =
          CherryLilyPaths.normalizedWorktreeBaseDirectoryPath(globalDefaultWorktreeBaseDirectoryPath)
        state.globalCopyIgnoredOnWorktreeCreate = globalCopyIgnoredOnWorktreeCreate
        state.globalCopyUntrackedOnWorktreeCreate = globalCopyUntrackedOnWorktreeCreate
        state.globalPullRequestMergeStrategy = globalPullRequestMergeStrategy
        state.isBareRepository = isBareRepository
        guard updatedSettings != settings else { return .none }
        let rootURL = state.rootURL
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0 = updatedSettings }
        return .send(.delegate(.settingsChanged(rootURL)))

      case .branchDataLoaded(let branches, let defaultBaseRef):
        state.defaultWorktreeBaseRef = defaultBaseRef
        var options = branches
        if !options.contains(defaultBaseRef) {
          options.append(defaultBaseRef)
        }
        if let selected = state.settings.worktreeBaseRef, !options.contains(selected) {
          options.append(selected)
        }
        state.branchOptions = options
        state.isBranchDataLoaded = true
        return .none

      case .binding:
        if state.isBareRepository {
          state.settings.copyIgnoredOnWorktreeCreate = nil
          state.settings.copyUntrackedOnWorktreeCreate = nil
        }
        let rootURL = state.rootURL
        var normalizedSettings = state.settings
        normalizedSettings.worktreeBaseDirectoryPath = CherryLilyPaths.normalizedWorktreeBaseDirectoryPath(
          normalizedSettings.worktreeBaseDirectoryPath,
          repositoryRootURL: rootURL
        )
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0 = normalizedSettings }
        return .send(.delegate(.settingsChanged(rootURL)))

      case .delegate:
        return .none
      }
    }
  }
}

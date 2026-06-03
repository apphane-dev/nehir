import Foundation
import NehirIPC

enum CLICompletionGenerator {
    private static let subscribeFlags = ["--all", "--no-send-initial"]
    private static let watchFlags = ["--all", "--no-send-initial", "--exec"]

    static func script(for shell: CLIShell) -> String {
        switch shell {
        case .zsh:
            zshScript()
        case .bash:
            bashScript()
        case .fish:
            fishScript()
        }
    }

    private static func zshScript() -> String {
        """
        #compdef nehirctl

        _nehirctl() {
          local cur
          cur="${words[CURRENT]}"

          local suggestions=""
          if (( CURRENT == 2 )); then
            suggestions="\(shellWords(topLevelCommands))"
            compadd -- ${=suggestions}
            return
          fi

          case "${words[2]}" in
            query)
              if (( CURRENT == 3 )); then
                suggestions="\(shellWords(queryNames))"
              else
                local query_name="${words[3]}"
                local prev="${words[CURRENT-1]}"
                if [[ "$prev" == "--fields" ]]; then
                  case "$query_name" in
                    \(renderZshCase(map: queryFieldsByName))
                  esac
                else
                  case "$query_name" in
                    \(renderZshCase(map: queryFlagsByName))
                  esac
                fi
              fi
              ;;
            command)
              local command_prefix=""
              local i
              for (( i = 3; i < CURRENT; i++ )); do
                command_prefix="${command_prefix:+$command_prefix }${words[i]}"
              done
              case "$command_prefix" in
                \(renderZshCase(map: commandSuggestionsByPrefix))
              esac
              ;;
            rule)
              if (( CURRENT == 3 )); then
                suggestions="\(shellWords(ruleActionNames))"
              elif [[ "${words[3]}" == "add" || "${words[3]}" == "replace" ]]; then
                local prev="${words[CURRENT-1]}"
                if [[ " \(shellWords(ruleDefinitionFlags)) " != *" $prev "* ]]; then
                  suggestions="\(shellWords(ruleDefinitionFlags))"
                fi
              elif [[ "${words[3]}" == "apply" ]]; then
                local prev="${words[CURRENT-1]}"
                if [[ "$prev" != "--window" && "$prev" != "--pid" ]]; then
                  suggestions="\(shellWords(ruleApplyFlags))"
                fi
              fi
              ;;
            subscribe)
              if [[ " ${words[*]} " != *" --exec "* ]]; then
                suggestions="\(shellWords(sortedUnique(subscriptionNames + subscribeFlags)))"
              fi
              ;;
            watch)
              if [[ " ${words[*]} " != *" --exec "* ]]; then
                suggestions="\(shellWords(sortedUnique(subscriptionNames + watchFlags)))"
              fi
              ;;
            workspace)
              suggestions="\(shellWords(workspaceActionNames))"
              ;;
            window)
              suggestions="\(shellWords(windowActionNames))"
              ;;
            completion)
              suggestions="zsh bash fish"
              ;;
          esac

          [[ -n "$suggestions" ]] && compadd -- ${=suggestions}
        }

        _nehirctl "$@"
        """
    }

    private static func bashScript() -> String {
        """
        _nehirctl()
        {
          local cur prev command first second query_name suggestions
          COMPREPLY=()
          cur="${COMP_WORDS[COMP_CWORD]}"
          prev="${COMP_WORDS[COMP_CWORD-1]}"
          command="${COMP_WORDS[1]}"

          __nehirctl_compgen() {
            COMPREPLY=( $(compgen -W "$1" -- "$cur") )
          }

          if [[ ${COMP_CWORD} -eq 1 ]]; then
            __nehirctl_compgen "\(shellWords(topLevelCommands))"
            return 0
          fi

          case "$command" in
            query)
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                __nehirctl_compgen "\(shellWords(queryNames))"
                return 0
              fi

              query_name="${COMP_WORDS[2]}"
              suggestions=""
              if [[ "$prev" == "--fields" ]]; then
                case "$query_name" in
                  \(renderBashCase(map: queryFieldsByName))
                esac
              else
                case "$query_name" in
                  \(renderBashCase(map: queryFlagsByName))
                esac
              fi
              __nehirctl_compgen "$suggestions"
              return 0
              ;;
            command)
              local command_prefix="" i
              for (( i = 2; i < COMP_CWORD; i++ )); do
                command_prefix="${command_prefix:+$command_prefix }${COMP_WORDS[i]}"
              done
              suggestions=""
              case "$command_prefix" in
                \(renderBashCase(map: commandSuggestionsByPrefix))
              esac
              __nehirctl_compgen "$suggestions"
              return 0
              ;;
            rule)
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                __nehirctl_compgen "\(shellWords(ruleActionNames))"
                return 0
              fi
              if [[ "${COMP_WORDS[2]}" == "add" || "${COMP_WORDS[2]}" == "replace" ]]; then
                if [[ " \(shellWords(ruleDefinitionFlags)) " != *" $prev "* ]]; then
                  __nehirctl_compgen "\(shellWords(ruleDefinitionFlags))"
                  return 0
                fi
              fi
              if [[ "${COMP_WORDS[2]}" == "apply" && "$prev" != "--window" && "$prev" != "--pid" ]]; then
                __nehirctl_compgen "\(shellWords(ruleApplyFlags))"
                return 0
              fi
              ;;
            subscribe)
              if [[ " ${COMP_WORDS[*]} " != *" --exec "* ]]; then
                __nehirctl_compgen "\(shellWords(sortedUnique(subscriptionNames + subscribeFlags)))"
                return 0
              fi
              ;;
            watch)
              if [[ " ${COMP_WORDS[*]} " != *" --exec "* ]]; then
                __nehirctl_compgen "\(shellWords(sortedUnique(subscriptionNames + watchFlags)))"
                return 0
              fi
              ;;
            workspace)
              __nehirctl_compgen "\(shellWords(workspaceActionNames))"
              return 0
              ;;
            window)
              __nehirctl_compgen "\(shellWords(windowActionNames))"
              return 0
              ;;
            completion)
              __nehirctl_compgen "zsh bash fish"
              return 0
              ;;
          esac
        }

        complete -F _nehirctl nehirctl
        """
    }

    private static func fishScript() -> String {
        let helperFunctions = """
        function __nehirctl_prev_arg_is
            set -l tokens (commandline -opc)
            test (count $tokens) -gt 0; or return 1
            set -l prev $tokens[-1]
            contains -- $prev $argv
        end
        """

        let baseLines = topLevelCommands.map { command in
            "complete -c nehirctl -f -n '__fish_use_subcommand' -a '\(command)'"
        }
        let queryLines = queryNames.map { query in
            "complete -c nehirctl -f -n '__fish_seen_subcommand_from query' -a '\(query)'"
        }
        let queryFlagLines = queryFlagsByName.flatMap { queryName, flags in
            flags.map { flag in
                "complete -c nehirctl -f -n '__fish_seen_subcommand_from query; and __fish_seen_subcommand_from \(queryName)' -a '\(flag)'"
            }
        }
        let queryFieldLines = queryFieldsByName.flatMap { queryName, fields in
            fields.map { field in
                "complete -c nehirctl -f -n '__fish_seen_subcommand_from query; and __fish_seen_subcommand_from \(queryName); and __nehirctl_prev_arg_is --fields' -a '\(field)'"
            }
        }
        let commandCompletionLines = commandSuggestionsByPrefix.flatMap { prefix, suggestions in
            suggestions.map { suggestion in
                "complete -c nehirctl -f -n '\(fishCommandCondition(for: prefix))' -a '\(suggestion)'"
            }
        }
        let ruleLines = ruleActionNames.map { action in
            "complete -c nehirctl -f -n '__fish_seen_subcommand_from rule' -a '\(action)'"
        }
        let ruleDefinitionLines = ruleDefinitionFlags.flatMap { flag in
            [
                "complete -c nehirctl -f -n '__fish_seen_subcommand_from rule; and __fish_seen_subcommand_from add' -a '\(flag)'",
                "complete -c nehirctl -f -n '__fish_seen_subcommand_from rule; and __fish_seen_subcommand_from replace' -a '\(flag)'"
            ]
        }
        let ruleApplyLines = ruleApplyFlags.map { flag in
            "complete -c nehirctl -f -n '__fish_seen_subcommand_from rule; and __fish_seen_subcommand_from apply' -a '\(flag)'"
        }
        let subscribeLines = sortedUnique(subscriptionNames + subscribeFlags).map { token in
            "complete -c nehirctl -f -n '__fish_seen_subcommand_from subscribe' -a '\(token)'"
        }
        let watchLines = sortedUnique(subscriptionNames + watchFlags).map { token in
            "complete -c nehirctl -f -n '__fish_seen_subcommand_from watch' -a '\(token)'"
        }
        let workspaceLines = workspaceActionNames.map { action in
            "complete -c nehirctl -f -n '__fish_seen_subcommand_from workspace' -a '\(action)'"
        }
        let windowLines = windowActionNames.map { action in
            "complete -c nehirctl -f -n '__fish_seen_subcommand_from window' -a '\(action)'"
        }
        let shellLines = CLIShell.allCases.map { shell in
            "complete -c nehirctl -f -n '__fish_seen_subcommand_from completion' -a '\(shell.rawValue)'"
        }

        return (
            [helperFunctions]
                + baseLines
                + queryLines
                + queryFlagLines.sorted()
                + queryFieldLines.sorted()
                + commandCompletionLines.sorted()
                + ruleLines
                + ruleDefinitionLines
                + ruleApplyLines
                + subscribeLines
                + watchLines
                + workspaceLines
                + windowLines
                + shellLines
        )
        .joined(separator: "\n")
    }

    private static var topLevelCommands: [String] {
        [
            "ping",
            "version",
            "help",
            "completion",
            "command",
            "query",
            "rule",
            "workspace",
            "window",
            "subscribe",
            "watch"
        ]
    }

    private static var queryNames: [String] {
        sortedUnique(IPCAutomationManifest.queryDescriptors.map(\.name.rawValue))
    }

    private static var subscriptionNames: [String] {
        IPCSubscriptionChannel.allCases.map(\.rawValue)
    }

    private static var ruleActionNames: [String] {
        IPCAutomationManifest.ruleActionDescriptors.map(\.name.rawValue)
    }

    private static var ruleApplyFlags: [String] {
        IPCAutomationManifest.ruleActionDescriptor(for: .apply)?.options.map(\.flag) ?? []
    }

    private static var ruleDefinitionFlags: [String] {
        IPCAutomationManifest.ruleDefinitionOptionDescriptors.map(\.flag)
    }

    private static var workspaceActionNames: [String] {
        IPCAutomationManifest.workspaceActionDescriptors.map(\.name.rawValue)
    }

    private static var windowActionNames: [String] {
        IPCAutomationManifest.windowActionDescriptors.map(\.name.rawValue)
    }

    private static var commandSuggestionsByPrefix: [String: [String]] {
        var map: [String: Set<String>] = [:]

        for descriptor in IPCAutomationManifest.commandDescriptors {
            for index in descriptor.commandWords.indices {
                let prefix = pathKey(Array(descriptor.commandWords.prefix(index)))
                map[prefix, default: []].insert(descriptor.commandWords[index])
            }

            if let literals = literalValues(for: descriptor.arguments.first?.kind) {
                map[pathKey(descriptor.commandWords), default: []].formUnion(literals)
            }
        }

        return map.mapValues { Array($0).sorted() }
    }

    private static func fishCommandCondition(for prefix: String) -> String {
        let prefixWords = prefix.split(separator: " ").map(String.init)
        return (["__fish_seen_subcommand_from command"] + prefixWords.map { "__fish_seen_subcommand_from \($0)" })
            .joined(separator: "; and ")
    }

    private static var queryFlagsByName: [String: [String]] {
        var map: [String: [String]] = [:]
        for descriptor in IPCAutomationManifest.queryDescriptors {
            let flags = sortedUnique(selectorFlags(for: descriptor) + (descriptor.fields.isEmpty ? [] : ["--fields"]))
            map[descriptor.name.rawValue] = flags
        }
        return map
    }

    private static var queryFieldsByName: [String: [String]] {
        Dictionary(
            uniqueKeysWithValues: IPCAutomationManifest.queryDescriptors.map { descriptor in
                (descriptor.name.rawValue, descriptor.fields)
            }
        )
    }

    private static func selectorFlags(for descriptor: IPCQueryDescriptor) -> [String] {
        descriptor.selectors.map(\.name.flag)
    }

    private static func literalValues(for kind: IPCCommandArgumentKind?) -> [String]? {
        guard let kind else { return nil }
        switch kind {
        case .direction:
            return ["left", "right", "up", "down"]
        case .resizeOperation:
            return ["grow", "shrink"]
        case .workspaceNumber,
             .columnIndex,
             .windowIndex,
             .sizeChange:
            return nil
        case .traceDesiredState:
            return ["active", "inactive"]
        }
    }

    private static func pathKey(_ words: [String]) -> String {
        words.joined(separator: " ")
    }

    private static func renderZshCase(map: [String: [String]]) -> String {
        map.keys.sorted().map { key in
            """
            \(quotedCasePattern(key)))
                            suggestions="\(shellWords(map[key] ?? []))"
                            ;;
            """
        }
        .joined(separator: "\n                  ")
    }

    private static func renderBashCase(map: [String: [String]]) -> String {
        map.keys.sorted().map { key in
            """
            \(quotedCasePattern(key)))
                  suggestions="\(shellWords(map[key] ?? []))"
                  ;;
            """
        }
        .joined(separator: "\n                ")
    }

    private static func quotedCasePattern(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func shellWords(_ words: [String]) -> String {
        sortedUnique(words).joined(separator: " ")
    }
}

import { Action, ActionPanel, Detail, Icon, List } from "@raycast/api";
import { useEffect, useState } from "react";
import {
  commands as fallbackCommands,
  discoverCommands,
  executeNehir,
  NehirCommand,
  queries as fallbackQueries,
} from "./commands";

function iconFor(command: NehirCommand) {
  const text = command.args.join(" ");
  if (text.startsWith("query")) return Icon.MagnifyingGlass;
  if (text.includes("focus")) return Icon.Target;
  if (text.includes("move")) return Icon.ArrowRight;
  if (text.includes("workspace")) return Icon.Sidebar;
  if (text.includes("toggle")) return Icon.Switch;
  if (text.includes("settings")) return Icon.Gear;
  if (text.includes("scratchpad")) return Icon.Tray;
  if (text.includes("debug")) return Icon.Bug;
  return Icon.Terminal;
}

function CommandItem({ command }: { command: NehirCommand }) {
  const runnable = !command.needsArguments;
  return (
    <List.Item
      key={command.id}
      icon={iconFor(command)}
      title={command.title}
      subtitle={command.subtitle}
      accessories={[{ text: command.needsArguments ? "needs args" : command.args.join(" ") }]}
      actions={
        <ActionPanel>
          {runnable ? (
            <Action title="Run" icon={Icon.Play} onAction={() => executeNehir(command.title, command.args)} />
          ) : null}
          <Action.Push
            title="Show Command"
            icon={Icon.Terminal}
            target={
              <Detail
                markdown={`# ${command.title}\n\n${command.subtitle}\n\n\`nehirctl ${command.args.join(" ")}\``}
              />
            }
          />
          <Action.CopyToClipboard title="Copy CLI Command" content={`nehirctl ${command.args.join(" ")}`} />
        </ActionPanel>
      }
    />
  );
}

export default function Command() {
  const [items, setItems] = useState({ commands: fallbackCommands, queries: fallbackQueries, discovered: false });
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    discoverCommands()
      .then(setItems)
      .finally(() => setIsLoading(false));
  }, []);

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search Nehir commands…" throttle>
      <List.Section
        title={items.discovered ? "Discovered IPC Commands" : "Bundled IPC Commands"}
        subtitle={`${items.commands.length}`}
      >
        {items.commands.map((command) => (
          <CommandItem key={command.id} command={command} />
        ))}
      </List.Section>
      <List.Section
        title={items.discovered ? "Discovered IPC Queries" : "Bundled IPC Queries"}
        subtitle={`${items.queries.length}`}
      >
        {items.queries.map((command) => (
          <CommandItem key={command.id} command={command} />
        ))}
      </List.Section>
    </List>
  );
}

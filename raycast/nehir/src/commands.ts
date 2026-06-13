import { Toast, showToast } from "@raycast/api";
import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const HOME_CLI_CANDIDATES = process.env.HOME
  ? [
      `${process.env.HOME}/Applications/Nehir.app/Contents/MacOS/nehirctl`,
      `${process.env.HOME}/.local/bin/nehirctl`,
      `${process.env.HOME}/bin/nehirctl`,
    ]
  : [];

const CLI_CANDIDATES = [
  "/Applications/Nehir.app/Contents/MacOS/nehirctl",
  "/Applications/Setapp/Nehir.app/Contents/MacOS/nehirctl",
  ...HOME_CLI_CANDIDATES,
  "/opt/homebrew/bin/nehirctl",
  "/usr/local/bin/nehirctl",
];

export type NehirCommand = {
  id: string;
  title: string;
  subtitle: string;
  args: string[];
  needsArguments?: boolean;
};

type Descriptor = {
  path?: string;
  summary?: string;
  commandWords?: string[];
  actionWords?: string[];
  name?: string;
  arguments?: unknown[];
};

const fallbackCommandDescriptors: Descriptor[] = [
  { path: "command focus <left|right|up|down>", summary: "Focus a neighboring window.", arguments: ["direction"] },
  { path: "command focus previous", summary: "Focus the previously focused window." },
  { path: "command focus down-or-left", summary: "Traverse backward through the active Niri workspace." },
  { path: "command focus up-or-right", summary: "Traverse forward through the active Niri workspace." },
  { path: "command focus-window top", summary: "Focus the top window in the focused Niri column." },
  { path: "command focus-window bottom", summary: "Focus the bottom window in the focused Niri column." },
  { path: "command focus-window down-or-top", summary: "Focus down in the focused Niri column, wrapping to the top." },
  {
    path: "command focus-window up-or-bottom",
    summary: "Focus up in the focused Niri column, wrapping to the bottom.",
  },
  { path: "command focus-window-or-workspace-down", summary: "Focus down, or switch to the workspace below." },
  { path: "command focus-window-or-workspace-up", summary: "Focus up, or switch to the workspace above." },
  { path: "command focus-column first", summary: "Focus the first Niri column." },
  { path: "command focus-column last", summary: "Focus the last Niri column." },
  { path: "command scroll-viewport left", summary: "Scroll the Niri viewport left." },
  { path: "command scroll-viewport right", summary: "Scroll the Niri viewport right." },
  { path: "command move <left|right|up|down>", summary: "Move the focused window.", arguments: ["direction"] },
  { path: "command move-window-down", summary: "Move the focused Niri window down within its column." },
  { path: "command move-window-up", summary: "Move the focused Niri window up within its column." },
  { path: "command move-window-down-or-to-workspace-down", summary: "Move down, or to the workspace below." },
  { path: "command move-window-up-or-to-workspace-up", summary: "Move up, or to the workspace above." },
  { path: "command consume-or-expel-window-left", summary: "Consume or expel the focused window left." },
  { path: "command consume-or-expel-window-right", summary: "Consume or expel the focused window right." },
  { path: "command consume-window-into-column", summary: "Consume a window into the focused column." },
  { path: "command expel-window-from-column", summary: "Expel a window from the focused column." },
  { path: "command switch-workspace next", summary: "Switch to the next workspace." },
  { path: "command switch-workspace prev", summary: "Switch to the previous workspace." },
  { path: "command switch-workspace back-and-forth", summary: "Switch to the previously active workspace." },
  { path: "command move-to-workspace up", summary: "Move focused window to the workspace above." },
  { path: "command move-to-workspace down", summary: "Move focused window to the workspace below." },
  { path: "command focus-monitor prev", summary: "Move interaction focus to the previous monitor." },
  { path: "command focus-monitor next", summary: "Move interaction focus to the next monitor." },
  { path: "command focus-monitor last", summary: "Move interaction focus back to the previous monitor." },
  { path: "command move-column left", summary: "Move the focused Niri column left." },
  { path: "command move-column right", summary: "Move the focused Niri column right." },
  { path: "command move-column up", summary: "Move the focused Niri column up." },
  { path: "command move-column down", summary: "Move the focused Niri column down." },
  { path: "command move-column-to-first", summary: "Move the focused Niri column to the first position." },
  { path: "command move-column-to-last", summary: "Move the focused Niri column to the last position." },
  { path: "command move-column-to-workspace up", summary: "Move focused column to the workspace above." },
  { path: "command move-column-to-workspace down", summary: "Move focused column to the workspace below." },
  { path: "command toggle-column-tabbed", summary: "Toggle tabbed mode for the focused Niri column." },
  { path: "command toggle-column-full-width", summary: "Toggle full-width mode for the focused Niri column." },
  { path: "command cycle-column-width forward", summary: "Cycle Niri column width presets forward." },
  { path: "command cycle-column-width backward", summary: "Cycle Niri column width presets backward." },
  { path: "command cycle-window-width forward", summary: "Cycle Niri window width presets forward." },
  { path: "command cycle-window-width backward", summary: "Cycle Niri window width presets backward." },
  { path: "command cycle-window-height forward", summary: "Cycle Niri window height presets forward." },
  { path: "command cycle-window-height backward", summary: "Cycle Niri window height presets backward." },
  { path: "command expand-column-to-available-width", summary: "Expand focused column into available space." },
  { path: "command reset-window-height", summary: "Reset focused Niri window height." },
  { path: "command balance-sizes", summary: "Balance layout sizes in the active workspace." },
  { path: "command open-command-palette", summary: "Toggle the command palette." },
  { path: "command open-menu-anywhere", summary: "Open the menu surface anywhere." },
  { path: "command open-settings", summary: "Open the Nehir settings window." },
  { path: "command raise-all-floating-windows", summary: "Raise all visible floating windows." },
  { path: "command rescue-offscreen-windows", summary: "Clamp floating windows back onto visible monitors." },
  { path: "command toggle-focused-window-floating", summary: "Toggle focused window between tiled and floating." },
  { path: "command scratchpad assign", summary: "Assign focused window to scratchpad." },
  { path: "command scratchpad toggle", summary: "Show or hide scratchpad window." },
  { path: "command toggle-workspace-bar", summary: "Toggle workspace bar visibility." },
  { path: "command toggle-fullscreen", summary: "Toggle Nehir-managed fullscreen." },
  { path: "command toggle-native-fullscreen", summary: "Toggle native macOS fullscreen." },
  { path: "command toggle-overview", summary: "Toggle the overview surface." },
  { path: "command toggle-focus-follows-mouse", summary: "Toggle focus-follows-mouse." },
  {
    path: "command toggle-focus-follows-window-to-monitor",
    summary: "Toggle following a window when it moves monitor.",
  },
  { path: "command toggle-move-mouse-to-focused", summary: "Toggle moving the cursor to focused window." },
  { path: "command toggle-borders", summary: "Toggle window border rendering." },
  { path: "command toggle-prevent-sleep", summary: "Toggle display sleep prevention." },
  { path: "command toggle-ipc", summary: "Toggle the IPC server." },
  { path: "ping", summary: "Verify IPC reachability." },
  { path: "version --format json", summary: "Return Nehir and IPC protocol versions." },
];

const fallbackQueryNames = [
  "workspace-bar",
  "active-workspace",
  "focused-monitor",
  "apps",
  "focused-window",
  "windows",
  "workspaces",
  "displays",
  "rules",
  "rule-actions",
  "queries",
  "commands",
  "subscriptions",
  "capabilities",
  "focused-window-decision",
  "reconcile-debug",
];

function titleize(value: string) {
  return value
    .replace(/^command /, "")
    .replace(/--format json/g, "")
    .trim()
    .split(/[ -]/)
    .filter(Boolean)
    .map((part) => part[0]?.toUpperCase() + part.slice(1))
    .join(" ");
}

function descriptorToCommand(descriptor: Descriptor, fallbackPrefix: string): NehirCommand | undefined {
  const path =
    descriptor.path ??
    (descriptor.commandWords ? `command ${descriptor.commandWords.join(" ")}` : undefined) ??
    (descriptor.actionWords ? `${fallbackPrefix} ${descriptor.actionWords.join(" ")}` : undefined) ??
    descriptor.name;
  if (!path) return undefined;
  const args = path.split(/\s+/).filter(Boolean);
  const needsArguments =
    args.some((arg) => arg.startsWith("<") || arg.includes("|")) || Boolean(descriptor.arguments?.length);
  return { id: args.join("-"), title: titleize(path), subtitle: descriptor.summary ?? path, args, needsArguments };
}

function queryToCommand(query: string | Descriptor): NehirCommand | undefined {
  const name = typeof query === "string" ? query : query.name;
  if (!name) return undefined;
  return {
    id: `query-${name}`,
    title: `Query ${titleize(name)}`,
    subtitle: typeof query === "string" ? "Run Nehir IPC query" : (query.summary ?? "Run Nehir IPC query"),
    args: ["query", name, "--format", "json"],
  };
}

export const commands: NehirCommand[] = fallbackCommandDescriptors
  .map((descriptor) => descriptorToCommand(descriptor, "command"))
  .filter((command): command is NehirCommand => Boolean(command));
export const queries: NehirCommand[] = fallbackQueryNames
  .map((name) => queryToCommand(name))
  .filter((command): command is NehirCommand => Boolean(command));

let cachedCli: string | undefined;

async function findCli(): Promise<string> {
  if (cachedCli) return cachedCli;
  for (const candidate of CLI_CANDIDATES) {
    try {
      await access(candidate);
      cachedCli = candidate;
      return cachedCli;
    } catch {
      // Try the next known install location.
    }
  }
  cachedCli = "nehirctl";
  return cachedCli;
}

export async function runNehir(args: string[]): Promise<string> {
  const cli = await findCli();
  const { stdout, stderr } = await execFileAsync(cli, args, { timeout: 10000, env: process.env });
  if (stderr.trim()) {
    const error = new Error(stderr.trim());
    console.warn("nehirctl wrote to stderr", error.message);
    throw error;
  }
  return stdout.trim();
}

function parsePayload(output: string): unknown {
  const parsed = JSON.parse(output);
  if (parsed && typeof parsed === "object" && "result" in parsed) {
    const result = (parsed as { result?: unknown }).result;
    if (result && typeof result === "object" && "payload" in result) return (result as { payload: unknown }).payload;
    return result;
  }
  if (parsed && typeof parsed === "object" && "payload" in parsed) return (parsed as { payload: unknown }).payload;
  return parsed;
}

function extractArray(payload: unknown, keys: string[]): unknown[] | undefined {
  if (Array.isArray(payload)) return payload;
  if (!payload || typeof payload !== "object") return undefined;
  for (const key of keys) {
    const value = (payload as Record<string, unknown>)[key];
    if (Array.isArray(value)) return value;
  }
  return undefined;
}

export async function discoverCommands(): Promise<{
  commands: NehirCommand[];
  queries: NehirCommand[];
  discovered: boolean;
}> {
  try {
    const [commandOutput, queryOutput] = await Promise.all([
      runNehir(["query", "commands", "--format", "json"]),
      runNehir(["query", "queries", "--format", "json"]),
    ]);
    const commandPayload = parsePayload(commandOutput);
    const queryPayload = parsePayload(queryOutput);
    const commandItems = extractArray(commandPayload, ["commands", "descriptors", "items"]);
    const queryItems = extractArray(queryPayload, ["queries", "descriptors", "items"]);
    const discoveredCommands =
      commandItems
        ?.map((item) => descriptorToCommand(item as Descriptor, "command"))
        .filter((command): command is NehirCommand => Boolean(command)) ?? [];
    const discoveredQueries =
      queryItems
        ?.map((item) => queryToCommand(item as Descriptor))
        .filter((command): command is NehirCommand => Boolean(command)) ?? [];
    return {
      commands: discoveredCommands.length ? discoveredCommands : commands,
      queries: discoveredQueries.length ? discoveredQueries : queries,
      discovered: Boolean(discoveredCommands.length || discoveredQueries.length),
    };
  } catch (e) {
    console.warn("discoverCommands failed", e instanceof Error ? (e.stack ?? e.message) : String(e));
    return { commands, queries, discovered: false };
  }
}

export async function executeNehir(title: string, args: string[]) {
  const toast = await showToast({ style: Toast.Style.Animated, title: `Running ${title}` });
  try {
    const output = await runNehir(args);
    toast.style = Toast.Style.Success;
    toast.title = `${title} completed`;
    toast.message = output || undefined;
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = `${title} failed`;
    const stderr = typeof error === "object" && error && "stderr" in error ? String(error.stderr).trim() : "";
    toast.message = stderr || (error instanceof Error ? error.message : String(error));
  }
}

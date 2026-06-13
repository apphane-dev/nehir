import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Open Nehir Settings", ["command", "open-settings"]);
}

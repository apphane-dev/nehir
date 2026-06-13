import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Consume or Expel Window Left", ["command", "consume-or-expel-window-left"]);
}

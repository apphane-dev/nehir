import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Consume or Expel Window Right", ["command", "consume-or-expel-window-right"]);
}

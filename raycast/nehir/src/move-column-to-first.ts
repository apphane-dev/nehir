import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move Column to First", ["command", "move-column-to-first"]);
}

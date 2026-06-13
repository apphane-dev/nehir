import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move Column to Last", ["command", "move-column-to-last"]);
}

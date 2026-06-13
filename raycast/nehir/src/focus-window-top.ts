import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Window Top", ["command", "focus-window", "top"]);
}

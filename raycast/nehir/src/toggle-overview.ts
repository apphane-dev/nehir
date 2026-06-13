import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Overview", ["command", "toggle-overview"]);
}

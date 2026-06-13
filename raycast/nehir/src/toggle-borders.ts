import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Borders", ["command", "toggle-borders"]);
}

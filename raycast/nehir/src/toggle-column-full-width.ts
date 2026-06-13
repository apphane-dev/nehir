import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Column Full Width", ["command", "toggle-column-full-width"]);
}

import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Column Tabbed", ["command", "toggle-column-tabbed"]);
}

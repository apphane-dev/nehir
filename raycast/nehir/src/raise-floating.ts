import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Raise Floating Windows", ["command", "raise-all-floating-windows"]);
}

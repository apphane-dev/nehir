import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Ping Nehir IPC", ["ping"]);
}

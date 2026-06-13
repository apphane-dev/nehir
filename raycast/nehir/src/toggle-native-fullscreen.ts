import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Native Fullscreen", ["command", "toggle-native-fullscreen"]);
}

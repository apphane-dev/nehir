import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Balance Sizes", ["command", "balance-sizes"]);
}

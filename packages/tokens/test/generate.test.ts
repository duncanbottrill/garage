import { describe, it, expect } from "vitest";
import tokens from "../tokens.json" with { type: "json" };
import { generateCss, generateSwift } from "../src/generate";
describe("token generators", () => {
  it("css has every colour and the hero type", () => {
    const css = generateCss(tokens);
    expect(css).toContain("--color-accent: #4FE3FF;"); expect(css).toContain('--type-numeral-hero: 600 84px/0.84 "Big Shoulders Display";'); expect(css).toContain("--radius-sheet: 28px;");
  });
  it("swift compiles-looking output", () => {
    const s = generateSwift(tokens);
    expect(s).toContain("public static let accent = Color(red:"); expect(s).toContain('numeralHero = TextStyle(family: "Big Shoulders Display", weight: .semibold, size: 84');
  });
});

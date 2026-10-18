import { describe, it, expect } from "vitest";
import tokens from "../tokens.json" with { type: "json" };
import { generateCss, generateSwift } from "../src/generate";
const kebab = (s: string) => s.replace(/[A-Z]/g, (m) => "-" + m.toLowerCase());
describe("token generators", () => {
  it("css has every colour and the hero type", () => {
    const css = generateCss(tokens);
    expect(css).toContain("--color-accent: #4FE3FF;"); expect(css).toContain('--type-numeral-hero: 600 84px/0.84 "Big Shoulders Display";'); expect(css).toContain("--radius-sheet: 28px;");
  });
  it("css contains every colour and radius variable", () => {
    const css = generateCss(tokens);
    for (const key of Object.keys(tokens.color)) expect(css).toContain(`--color-${kebab(key)}:`);
    for (const key of Object.keys(tokens.radius)) expect(css).toContain(`--radius-${kebab(key)}:`);
  });
  it("swift compiles-looking output", () => {
    const s = generateSwift(tokens);
    expect(s).toContain("public static let accent = Color(red:"); expect(s).toContain('numeralHero = TextStyle(family: "Big Shoulders Display", weight: .semibold, size: 84');
  });
  it("swift uses a non-reserved Typography enum name so the generated file compiles", () => {
    const s = generateSwift(tokens);
    expect(s).not.toContain("enum Type {");
    expect(s).toContain("enum Typography {");
  });
  it("swift declares every colour key as a static let", () => {
    const s = generateSwift(tokens);
    for (const key of Object.keys(tokens.color)) expect(s).toContain(`public static let ${key} =`);
  });
});

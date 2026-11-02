// Code 128 bar/space width encoder. Set C (start 105) when the value is all
// digits with even length, otherwise set B (start 104). Checksum is
// (start + sum(code * position)) mod 103, then stop 106.
// renderCode128 renders the bars as one SVG.

const PATTERNS = [
  "212222","222122","222221","121223","121322","131222","122213","122312",
  "132212","221213","221312","231212","112232","122132","122231","113222",
  "123122","123221","223211","221132","221231","213212","223112","312131",
  "311222","321122","321221","312212","322112","322211","212123","212321",
  "232121","111323","131123","131321","112313","132113","132311","211313",
  "231113","231311","112133","112331","132131","113123","113321","133121",
  "313121","211331","231131","213113","213311","213131","311123","311321",
  "331121","312113","312311","332111","314111","221411","431111","111224",
  "111422","121124","121421","141122","141221","112214","112412","122114",
  "122411","142112","142211","241211","221114","413111","241112","134111",
  "111242","121142","121241","114212","124112","124211","411212","421112",
  "421211","212141","214121","412121","111143","111341","131141","114113",
  "114311","411113","411311","113141","114131","311141","411131","211412",
  "211214","211232","2331112",
];

export function encodeCode128(value: string): { codes: number[]; widths: string } {
  const codes: number[] = [];
  const useSetC = /^\d+$/.test(value) && value.length % 2 === 0;
  codes.push(useSetC ? 105 : 104);
  if (useSetC) {
    for (let i = 0; i < value.length; i += 2) {
      codes.push(Number(value.slice(i, i + 2)));
    }
  } else {
    for (const ch of value) {
      codes.push(ch.charCodeAt(0) - 32);
    }
  }
  let checksum = codes[0];
  for (let i = 1; i < codes.length; i++) checksum += codes[i] * i;
  codes.push(checksum % 103);
  codes.push(106);
  const widths = codes.map((c) => PATTERNS[c]).join("");
  return { codes, widths };
}

export function Code128Barcode({
  value,
  height = "1in",
  width = "100%",
}: {
  value: string;
  height?: string;
  width?: string;
}) {
  const { widths } = encodeCode128(value);
  // widths digits alternate bar/space starting with a bar.
  const quiet = 10;
  const modules = quiet * 2 + Array.from(widths).reduce((n, d) => n + Number(d), 0);
  let x = quiet;
  const rects: React.ReactElement[] = [];
  let bar = true;
  for (const d of widths) {
    const w = Number(d);
    if (bar) {
      rects.push(
        <rect key={rects.length} x={x} y={0} width={w} height={1} fill="black" />
      );
    }
    x += w;
    bar = !bar;
  }
  return (
    <svg
      viewBox={`0 0 ${modules} 1`}
      preserveAspectRatio="none"
      shapeRendering="crispEdges"
      style={{ display: "block", width, height }}
      role="img"
      aria-label={`barcode ${value}`}
    >
      {rects}
    </svg>
  );
}

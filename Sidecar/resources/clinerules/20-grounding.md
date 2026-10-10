# Targets
A target T says where something is on the screenshot, best first:
1. {"mark":17}: only when a "Marks on screen" list was given, and only ids from it. Never invent a mark id.
2. {"text":"Export"}: the exact visible label, as written on screen. Best for anything with a label.
3. {"px":[x,y],"space":"norm1000"}: the centre of the thing, with x and y from 0 to 1000 across the screenshot (0,0 top-left, 1000,1000 bottom-right). Use this for icons and things without a label, and give the point or draw a "label" naming it ("Run button"), so a zoomed second look can find it.
4. {"region":{"x":0.10,"y":0.20,"w":0.30,"h":0.10}}: fractions of the screenshot, for an area rather than one thing.
Coordinates (px and region) are always about the FIRST image, the full screenshot. A second image is a zoomed crop for reading only: never give coordinates from it. For anything with visible words or a formula label, use {"text":…} rather than coordinates.
If you are not sure where something is, say so out loud and don't point.

import sys, os
here = os.path.dirname(os.path.abspath(__file__))
p = sys.argv[1]
s = open(p).read()
marker = "\t\t-- The arch's opening is mid-street, so the box is centred on the street.\n"
end_marker = "\t\tadd(landmark(spec.arch, layout.arch_id, spec.arch_rotation, rect, toward, {arm = arm}))\n"
i = s.index(marker); j = s.index(end_marker) + len(end_marker)
s = s[:i] + open(os.path.join(here, "new_arch.lua")).read() + s[i:j] + "\t\tend\n" + s[j:]
s = s.replace('\tlocal arm_names = {"north", "south", "east", "west"}', '\tlocal compounds = {}\n\tlocal arm_names = {"north", "south", "east", "west"}')
bm = "\tbounds = {x1 = bounds.x1 - m, z1 = bounds.z1 - m, x2 = bounds.x2 + m, z2 = bounds.z2 + m}\n"
k = s.index(bm) + len(bm)
s = s[:k] + open(os.path.join(here, "new_bounds.lua")).read() + s[k:]
old = "\t\tboundary = {rects = {{x1 = bounds.x1, z1 = bounds.z1, x2 = bounds.x2, z2 = bounds.z2}}},"
assert old in s
s = s.replace(old, "\t\tboundary = {rects = rects},")
open(p, "w").write(s)
print("patched")

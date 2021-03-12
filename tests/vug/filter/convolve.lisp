(in-package :incudine-tests)

(dsp! direct-convolve-test-1 ((buf buffer))
  (out (direct-convolve (buzz 100 .5 200) buf)))

(dsp! part-convolve-test-1 (gain (pvb pvbuffer))
  (out (part-convolve (noise-test (db->linear gain)) pvb)))

(with-dsp-test (direct-convolve.1
      :md5 #+64-bit #(69 183 17 178 98 115 61 138 171 210 24 221 61 164 71 65)
           #-64-bit #(37 30 104 242 95 25 79 197 191 33 139 41 220 212 243 59))
  (direct-convolve-test-1 *filter-buffer-test-1*))

(with-dsp-test (direct-convolve.2
      :md5 #+64-bit #(180 38 62 18 63 40 89 197 91 225 139 131 78 164 117 62)
           #-64-bit #(99 134 236 142 185 228 22 29 47 66 227 223 168 13 234 183))
  (direct-convolve-test-1 *filter-buffer-test-2*))

(with-dsp-test (part-convolve.1
      :md5 #(10 96 63 66 36 73 49 255 9 16 174 58 179 253 133 24))
  (part-convolve-test-1 -24 *filter-pvbuffer-test-1*))

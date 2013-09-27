(in-package :incudine-tests)

(defun gen-random-test-1 (fn &key (size 64) (seed 12345) (scale 1))
  (cffi:with-foreign-object (arr 'sample size)
    (seed-random-state seed)
    (funcall fn arr size)
    (loop for i below size collect (sample->fixnum (* scale (smp-ref arr i))))))

(deftest gen-rand-linear
    (gen-random-test-1 (gen:rand :linear :a 0.0d0 :b 1000.0d0))
  (890 130 39 204 532 595 461 653 373 154 747 26 8 106 298 627 809 556 839
   50 642 717 364 325 129 729 318 676 596 170 26 698 821 24 491 526 596 51
   811 102 237 379 699 95 218 258 468 459 693 178 24 167 383 298 6 150 489
   375 493 14 249 315 568 187))

(deftest gen-rand-high
    (gen-random-test-1 (gen:rand :high :a 0.0d0 :b 1000.0d0))
  (929 316 183 826 567 956 964 923 748 653 892 961 291 398 807 656 907 872
   964 723 806 930 467 690 439 832 994 737 790 363 794 800 903 899 831 909
   974 656 895 728 818 500 810 484 415 638 759 557 709 913 531 837 768 928
   609 437 737 377 848 911 383 347 796 938))

(deftest gen-rand-triang
    (gen-random-test-1 (gen:rand :triang :a 0.0d0 :b 1000.0d0))
  (909 223 111 515 549 775 713 788 561 404 820 494 149 252 552 641 858 714
   902 387 724 824 415 508 284 781 656 707 693 267 410 749 862 462 661 718
   785 354 853 415 527 439 754 290 317 448 613 508 701 545 278 502 576 613
   307 293 613 376 670 462 316 331 682 563))

(deftest gen-rand-gauss
    (gen-random-test-1 (gen:rand :gauss :sigma 1000.0d0))
  (-927 704 127 -1841 -862 -1709 -195 751 634 756 1469 -439 485 -1135 2111
   1259 793 -283 1705 1120 1484 282 -2479 -415 1800 -29 -187 320 836 182
   1142 862 -1741 695 -867 -127 799 -343 -77 -698 -384 1179 1292 828 -1384
   -551 712 -993 -1444 883 652 1800 -191 -513 -280 919 -1206 -1444 -906 809
   -689 1420 -120 -480))

(deftest gen-rand-gauss-tail
    (gen-random-test-1 (gen:rand :gaussian-tail :a 1.0d0 :sigma 1000.0d0))
  (528 1179 517 606 462 928 1202 159 1135 336 1199 758 1161 441 631 1279 884
   346 150 596 762 1599 2287 1016 332 1720 1372 1114 1713 630 1221 298 767
   669 180 158 889 1126 683 242 368 808 124 2020 1023 208 702 1458 536 2351
   1686 314 149 930 279 1537 1651 550 185 139 1282 1554 1037 474))

(deftest gen-rand-expon
    (gen-random-test-1 (gen:rand :expon :mu 1000.0d0))
  (2653 2208 380 140 203 40 228 1751 838 759 905 3130 3338 619 1058 2573 1381
   468 1060 168 1377 2228 3252 27 8 344 112 508 354 1646 1068 986 1659 2385
   2057 812 3342 1832 1286 51 1028 1641 1263 2670 630 452 393 1174 579 138
   1308 1787 5118 383 1129 1336 1564 908 187 452 27 1584 1611 1198))

(deftest gen-rand-laplace
    (gen-random-test-1 (gen:rand :laplace :a 1000.0d0))
  (151 248 -1002 -304 -459 -83 -527 426 1999 2746 1655 91 73 -2576 1183 165
   697 -1378 1180 -371 702 242 80 -56 -17 -875 -240 -1597 -910 486 1162 1369
   478 203 295 2182 73 385 804 -107 1255 490 832 148 -2737 -1303 -1054 962
   -2115 -300 777 407 12 -1013 1039 745 541 1642 -419 -1300 -56 527 509 923))

(deftest gen-rand-exppow
    (gen-random-test-1 (gen:rand :exppow :a 1000.0d0 :b 1.5d0))
  (-765 -350 -402 1525 56 902 532 900 535 61 -13 -183 -695 886 365 225 613
   958 635 -2089 -804 -1614 593 9 793 413 -320 388 163 -84 179 598 344 364
   -163 -440 -557 -1916 663 -336 2111 -312 473 118 1159 -273 -1073 275 149
   -1114 -761 1518 -222 748 1462 1004 192 -928 646 -459 -514 408 142 88))

(deftest gen-rand-cauchy
    (gen-random-test-1 (gen:rand :cauchy :a 1000.0d0))
  (-225 -360 1536 435 652 125 748 -607 -4629 -9890 -3231 -139 -112 8320
   -1916 -245 -1007 2391 -1910 529 -1015 -352 -123 84 26 1301 347 3036
   1364 -693 -1869 -2370 -681 -298 -425 -5585 -112 -551 -1181 159 -2083
   -698 -1229 -221 9790 2196 1638 -1463 5210 430 -1137 -581 -19 1557 -1611
   -1084 -772 -3188 595 2190 84 -751 -725 -1391))

(deftest gen-rand-rayleigh
    (gen-random-test-1 (gen:rand :rayleigh :sigma 1000.0d0))
  (382 482 1517 2017 1840 2539 1781 617 1064 1123 1018 298 268 1242 922
   398 760 1402 922 1931 762 477 280 2690 3092 1570 2116 1356 1554 654
   917 966 649 439 522 1082 268 590 804 2443 940 656 814 378 1232 1421
   1498 859 1282 2022 793 605 109 1513 883 780 685 1016 1879 1422 2689
   677 667 847))

(deftest gen-rand-rayleigh-tail
    (gen-random-test-1 (gen:rand :rayleigh-tail :a 1.0d0 :sigma 1000.0d0))
  (382 482 1517 2017 1840 2539 1781 617 1064 1123 1018 298 268 1242 922
   398 760 1402 922 1931 762 477 280 2690 3092 1570 2116 1356 1554 654
   917 966 649 439 523 1082 268 590 804 2443 940 656 814 378 1233 1421
   1498 859 1282 2022 793 605 109 1513 883 780 685 1016 1879 1422 2689
   677 667 847))

(deftest gen-rand-landau
    (gen-random-test-1 (gen:rand :landau) :scale 100)
  (1627 1063 16 -90 -58 -161 -46 671 192 161 219 2548 3100 107 285 1508
   443 50 286 -75 440 1084 2857 -178 -216 2 -105 65 6 600 289 253 609
   1260 917 182 3111 730 393 -150 272 597 382 1653 111 44 21 338 92 -90
   404 698 17175 17 317 419 548 220 -65 44 -178 561 577 350))

(deftest gen-rand-levy
    (gen-random-test-1 (gen:rand :levy :c 1000.0d0 :alpha 1.0d0))
  (4448 2781 -651 -2297 -1534 -7965 -1336 1648 216 101 309 7239 8932
   -121 522 4093 993 -419 523 -1890 985 2843 8185 -11854 -37939 -769
   -2879 -330 -733 1444 535 421 1469 3360 2354 179 8966 1817 846 -6252
   480 1434 813 4528 -103 -456 -611 683 -192 -2325 879 1723 53174 -642
   620 922 1296 313 -1680 -457 -11828 1331 1379 719))

(deftest gen-rand-levy-skew
    (gen-random-test-1 (gen:rand :levy-skew :c 1000.0d0 :alpha 1.0d0))
  (13524 5058 5621 3251 4913 4180 23750 4724 6843 6464 5833 24191 4151
   3939 3451 5362 6897 9589 23130 7915 4924 5331 4767 3725 5417 5734
   113688 5350 7114 4072 3182 7129 10990 2945 3993 3960 4081 3440 10393
   7501 8483 4869 7342 3763 4024 3680 4039 4360 5760 3005 6895 3183 7126
   14490 8222 3897 4166 4439 8772 14664 4774 4347 4445 2934))

(deftest gen-rand-gamma
    (gen-random-test-1 (gen:rand :gamma :a 1.0d0 :b 100.0d0))
  (42 85 142 8 27 10 146 23 38 65 84 144 33 253 14 154 232 58 15 464 206
   103 41 136 30 106 19 28 313 39 3 144 4 11 397 40 5 60 41 97 7 27 38
   39 9 168 145 69 338 52 53 67 6 17 34 173 64 55 151 329 46 15 178 163))

(deftest gen-rand-uniform
    (gen-random-test-1 (gen:rand :uniform :a 0.0d0 :b 1000.0d0))
  (929 890 316 130 183 39 204 826 567 532 595 956 964 461 653 923 748 373
   653 154 747 892 961 26 8 291 106 398 298 807 656 627 809 907 872 556
   964 839 723 50 642 806 717 930 467 364 325 690 439 129 729 832 994 318
   676 737 790 596 170 363 26 794 800 698))

(deftest gen-rand-lognormal
    (gen-random-test-1 (gen:rand :lognormal :zeta 5.0d0 :sigma 1.0d0))
  (100 91 1790 165 251 184 579 228 198 61 80 651 425 251 175 87 49 124 250
   352 559 50 386 143 157 159 96 199 291 149 375 59 36 39 121 29 446 152
   106 567 227 46 137 35 493 77 39 203 360 273 180 375 139 75 513 149 120
   75 365 115 200 232 249 37))

(deftest gen-rand-chi-squared
    (gen-random-test-1 (gen:rand :chisq :nu 100.0d0))
  (129 94 102 109 83 90 67 86 77 126 119 123 99 96 104 88 88 118 85 79 83
   84 102 85 104 82 67 105 88 91 124 93 79 109 79 84 130 94 80 98 94 104
   82 90 93 93 83 112 109 99 126 96 96 99 81 87 92 112 99 97 110 70 125 95))

(deftest gen-rand-fdist
    (gen-random-test-1 (gen:rand :fdist :nu1 100.0d0 :nu2 1.0d0))
  (5 2 1 0 0 2 1 4 0 0 0 1 0 0 0 1 1 2 7 0 0 7101 5 1281 52 187 0 0 1 64 0
   2 17 1 1 0 4 0 25 30 2 2 37 0 0 1 9 13 6 1 1 2 0 3 19 4 14 0 7 0 10 0 0 1))

(deftest gen-rand-tdist
    (gen-random-test-1 (gen:rand :tdist :nu 1.0d0) :scale 100)
  (-274 44 -4 374 -65 51 47 -116 66 112 115 -2 523 172 -405 -215 158 161
   -45 -33 -2 -365 56 17 -791 33 197 126 -88 -2 119 152 -12 498 -93 -37
   -44 166 13 26 85 4 -267 -170 -23 24 -86 269 -62 -134 120 -36 137 -338
   29 93 121 39 42 52 -124 -22 21 610))

(deftest gen-rand-beta
    (gen-random-test-1 (gen:rand :beta :a 1.0d0 :b 1.0d0) :scale 100)
  (33 94 72 86 37 37 11 8 79 3 66 23 22 40 88 2 26 90 8 29 21 49 5 67 86 44
   25 16 53 31 75 52 55 31 10 64 57 49 96 40 65 22 32 29 67 44 11 25 43 88
   58 13 78 40 93 94 97 10 59 98 54 44 62 30))

(deftest gen-rand-logistic
    (gen-random-test-1 (gen:rand :logistic :a 100.0d0))
  (258 209 -78 -190 -150 -319 -136 156 27 12 38 308 330 -16 63 249 109 -52
   63 -170 108 211 321 -360 -478 -89 -213 -42 -86 143 64 51 144 228 192 22
   330 165 96 -294 58 142 93 259 -13 -56 -73 80 -25 -191 99 160 511 -77 73
   103 132 39 -158 -56 -360 135 138 84))

(deftest gen-rand-pareto
    (gen-random-test-1 (gen:rand :pareto :a 1.0d0 :b 100.0d0))
  (107 112 316 765 543 2515 488 121 176 187 167 104 103 216 153 108 133 267
   153 645 133 112 104 3732 11921 343 939 250 334 123 152 159 123 110 114
   179 103 119 138 1980 155 124 139 107 213 274 307 144 227 773 137 120 100
   314 147 135 126 167 585 274 3724 125 124 143))

(deftest gen-rand-weibull
    (gen-random-test-1 (gen:rand :weibull :a 100.0d0 :b 1.0d0))
  (7 11 115 203 169 322 158 19 56 63 51 4 3 77 42 7 28 98 42 186 29 11 3
   361 478 123 224 91 120 21 42 46 21 9 13 58 3 17 32 298 44 21 33 7 76
   101 112 36 82 204 31 18 0 114 39 30 23 51 176 101 361 22 22 35))

(deftest gen-rand-gumbel1
    (gen-random-test-1 (gen:rand :gumbel1 :a 1.0d0 :b 1.0d0) :scale 100)
  (261 215 -15 -72 -53 -118 -47 165 56 46 65 310 332 25 85 253 124 1 85
   -63 123 217 323 -129 -157 -21 -81 8 -19 154 86 76 155 233 198 53 332
   174 112 -110 81 153 110 263 27 -2 -12 99 19 -72 115 169 511 -14 94 118
   144 66 -57 -2 -129 147 150 102))

(deftest gen-rand-gumbel2
    (gen-random-test-1 (gen:rand :gumbel2 :a 1.0d0 :b 1.0d0) :scale 100)
  (1370 859 86 49 59 31 63 524 176 158 192 2238 2767 129 234 1260 345 101
   235 53 343 877 2534 27 20 81 44 108 82 467 237 214 474 1035 731 170
   2778 573 309 33 226 464 301 1394 131 98 89 270 121 48 317 546 16657 87
   256 327 426 193 56 98 27 435 449 278))

(deftest gen-rand-poisson
    (gen-random-test-1 (gen:rand :poisson :mu 100.0d0))
  (99 104 84 108 104 72 115 108 108 87 110 99 111 108 96 119 107 74 94 93
   108 98 94 108 113 109 92 88 100 89 102 95 113 88 116 92 100 88 108 123
   111 89 87 96 89 124 86 93 99 98 95 115 90 94 114 103 94 97 106 88 82
   90 82 106))

(deftest gen-rand-bernoulli
    (gen-random-test-1 (gen:rand :bernoulli :p 0.5d0))
  (0 0 1 1 1 1 1 0 0 0 0 0 0 1 0 0 0 1 0 1 0 0 0 1 1 1 1 1 1 0 0 0 0 0 0
   0 0 0 0 1 0 0 0 0 1 1 1 0 1 1 0 0 0 1 0 0 0 0 1 1 1 0 0 0))

(deftest gen-rand-binomial
    (gen-random-test-1 (gen:rand :binomial :p 0.5d0 :n 20))
  (13 13 9 7 8 6 8 12 10 10 11 14 14 10 11 13 12 9 11 8 11 13 14 6 5 9 7
   9 9 12 11 11 12 13 13 10 14 12 11 6 11 12 11 13 10 9 9 11 10 7 11 12
   15 9 11 11 12 11 8 9 6 12 12 11))

(deftest gen-rand-negative-binomial
    (gen-random-test-1 (gen:rand :negative-binomial :p 0.5d0 :n 20))
  (22 31 19 33 18 27 22 21 23 23 36 18 26 17 10 17 21 7 40 24 26 26 17 22
   20 18 10 18 20 29 28 30 13 15 21 22 23 28 16 16 20 18 12 28 11 13 25 22
   25 12 16 12 25 20 21 36 19 28 13 16 12 14 12 18))

(deftest gen-rand-pascal
    (gen-random-test-1 (gen:rand :pascal :p 0.2d0 :n 20))
  (99 91 106 92 64 86 75 74 115 56 88 38 79 61 76 71 70 126 102 76 116 84
   54 29 98 76 54 104 75 58 96 67 94 76 80 78 62 69 64 55 83 94 85 61 82 47
   103 61 85 61 80 59 67 69 110 60 108 56 109 97 126 71 67 84))

(deftest gen-rand-geom
    (gen-random-test-1 (gen:rand :geom :p 0.5d0))
  (1 1 2 3 3 5 3 1 1 1 1 1 1 2 1 1 1 2 1 3 1 1 1 6 7 2 4 2 2 1 1 1 1 1 1 1
   1 1 1 5 1 1 1 1 2 2 2 1 2 3 1 1 1 2 1 1 1 1 3 2 6 1 1 1))

(deftest gen-rand-hypergeom
    (gen-random-test-1 (gen:rand :hypergeom :n1 1 :n2 1))
  (1 1 0 0 0 0 0 1 1 1 1 1 1 0 1 1 1 0 1 0 1 1 1 0 0 0 0 0 0 1 1 1 1 1 1 1
   1 1 1 0 1 1 1 1 0 0 0 1 0 0 1 1 1 0 1 1 1 1 0 0 0 1 1 1))

(deftest gen-rand-log
    (gen-random-test-1 (gen:rand :log :p 0.5d0))
  (1 1 1 1 2 1 1 1 1 1 1 1 1 1 3 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 3 1 1 1 1 2
   1 1 1 1 2 1 1 1 2 5 1 1 1 1 5 1 1 1 1 1 3 1 1 1 3 2 2 1))

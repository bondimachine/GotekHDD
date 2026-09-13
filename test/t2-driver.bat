@echo off
dastub CARD.IMG > STUB.TXT
drvtest > T_DRV.TXT
drvtest /S 0 /N 2048 > T_SUM1.TXT
drvtest /S 63424 /N 32 > T_SUM2.TXT
drvtest /W 5000 > T_WR.TXT
drvtest /S 0 /N 2048 > T_SUM3.TXT

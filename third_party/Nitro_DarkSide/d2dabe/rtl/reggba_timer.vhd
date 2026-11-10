library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;
use work.pRegmap_gba.all;

package pReg_gba_timer is

   constant TM0CNT_L                   : regmap_type := (16#100#,  15,      0,        1,        0,   readwrite);
   constant TM0CNT_H                   : regmap_type := (16#100#,  31,     16,        1,        0,   readwrite);
   constant TM0CNT_H_Prescaler         : regmap_type := (16#100#,  17,     16,        1,        0,   readwrite);
   constant TM0CNT_H_Count_up          : regmap_type := (16#100#,  18,     18,        1,        0,   readwrite);
   constant TM0CNT_H_Timer_IRQ_Enable  : regmap_type := (16#100#,  22,     22,        1,        0,   readwrite);
   constant TM0CNT_H_Timer_Start_Stop  : regmap_type := (16#100#,  23,     23,        1,        0,   readwrite);

   constant TM1CNT_L                   : regmap_type := (16#104#,  15,      0,        1,        0,   readwrite);
   constant TM1CNT_H                   : regmap_type := (16#104#,  31,     16,        1,        0,   readwrite);
   constant TM1CNT_H_Prescaler         : regmap_type := (16#104#,  17,     16,        1,        0,   readwrite);
   constant TM1CNT_H_Count_up          : regmap_type := (16#104#,  18,     18,        1,        0,   readwrite);
   constant TM1CNT_H_Timer_IRQ_Enable  : regmap_type := (16#104#,  22,     22,        1,        0,   readwrite);
   constant TM1CNT_H_Timer_Start_Stop  : regmap_type := (16#104#,  23,     23,        1,        0,   readwrite);

   constant TM2CNT_L                   : regmap_type := (16#108#,  15,      0,        1,        0,   readwrite);
   constant TM2CNT_H                   : regmap_type := (16#108#,  31,     16,        1,        0,   readwrite);
   constant TM2CNT_H_Prescaler         : regmap_type := (16#108#,  17,     16,        1,        0,   readwrite);
   constant TM2CNT_H_Count_up          : regmap_type := (16#108#,  18,     18,        1,        0,   readwrite);
   constant TM2CNT_H_Timer_IRQ_Enable  : regmap_type := (16#108#,  22,     22,        1,        0,   readwrite);
   constant TM2CNT_H_Timer_Start_Stop  : regmap_type := (16#108#,  23,     23,        1,        0,   readwrite);

   constant TM3CNT_L                   : regmap_type := (16#10C#,  15,      0,        1,        0,   readwrite);
   constant TM3CNT_H                   : regmap_type := (16#10C#,  31,     16,        1,        0,   readwrite);
   constant TM3CNT_H_Prescaler         : regmap_type := (16#10C#,  17,     16,        1,        0,   readwrite);
   constant TM3CNT_H_Count_up          : regmap_type := (16#10C#,  18,     18,        1,        0,   readwrite);
   constant TM3CNT_H_Timer_IRQ_Enable  : regmap_type := (16#10C#,  22,     22,        1,        0,   readwrite);
   constant TM3CNT_H_Timer_Start_Stop  : regmap_type := (16#10C#,  23,     23,        1,        0,   readwrite);

end package;

ifeq ($(strip $(DEVKITARM)),)
$(error Set DEVKITPRO and DEVKITARM to your devkitPro installation)
endif
include $(DEVKITARM)/ds_rules

TARGET := nds-timing-probe
BUILD := build
ARCH := -march=armv5te -mtune=arm946e-s -marm
CFLAGS := -O2 -Wall -Wextra -ffunction-sections -fdata-sections $(ARCH) $(INCLUDE) -DARM9
ASFLAGS := -g $(ARCH)
LDFLAGS = -specs=ds_arm9.specs $(ARCH) -Wl,-Map,$(notdir $*.map)
LIBS := -lnds9
LIBDIRS := $(LIBNDS)
GAME_TITLE := ARM9 timing probe
GAME_SUBTITLE1 := ITCM and main RAM
GAME_SUBTITLE2 := open source homebrew

ifneq ($(BUILD),$(notdir $(CURDIR)))
export OUTPUT := $(CURDIR)/$(TARGET)
export VPATH := $(CURDIR)
export DEPSDIR := $(CURDIR)/$(BUILD)
export OFILES := main.o loops.o
export INCLUDE := $(foreach dir,$(LIBDIRS),-I$(dir)/include)
export LIBPATHS := $(foreach dir,$(LIBDIRS),-L$(dir)/lib)
export LD := $(CC)
.PHONY: all clean
all:
	@mkdir -p $(BUILD)
	@$(MAKE) --no-print-directory -C $(BUILD) -f $(CURDIR)/Makefile
clean:
	rm -rf $(BUILD) $(TARGET).elf $(TARGET).nds
else
$(OUTPUT).nds: $(OUTPUT).elf
$(OUTPUT).elf: $(OFILES)
-include $(OFILES:.o=.d)
endif

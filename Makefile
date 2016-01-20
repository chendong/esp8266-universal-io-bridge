SPI_FLASH_MODE		?= qio
IMAGE				?= ota
SDKROOT				?= /nfs/src/esp/opensdk
ESPTOOL				?= ~/bin/esptool
ESPTOOL2			?= ./esptool2
RBOOT				?= ./rboot
HOSTCC				?= gcc
OTA_HOST			?= 10.1.12.253

# no user serviceable parts below

section_free	= $(Q) perl -e '\
						open($$fd, "xtensa-lx106-elf-size -A $(1) |"); \
						$$available = $(5) * 1024; \
						$$used = 0; \
						while(<$$fd>) \
						{ \
							chomp; \
							@_ = split; \
							if(($$_[0] eq "$(3)") || ($$_[0] eq "$(4)")) \
							{ \
								$$used += $$_[1]; \
							} \
						} \
						$$free = $$available - $$used; \
						printf("    %-8s available: %3u k, used: %6u, free: %6u, %2u %%\n", "$(2)" . ":", $$available / 1024, $$used, $$free, 100 * $$free / $$available); \
						close($$fd);'

# use this line if you only want to see your own symbols in the output
#if((hex($$_[2]) > 0) && !m/\.a\(/)

link_debug		= $(Q) perl -e '\
						open($$fd, "< $(1)"); \
						$$top = 0; \
						while(<$$fd>) \
						{ \
							chomp; \
							if(m/^\s+\.$(2)/) \
							{ \
								@_ = split; \
								$$top = hex($$_[1]) if(hex($$_[1]) > $$top); \
								if(hex($$_[2]) > 0) \
								{ \
									$$size = sprintf("%06x", hex($$_[2])); \
									$$file = $$_[3]; \
									$$file =~ s/.*\///g; \
									$$size{"$$size-$$file"} = { size => $$size, id => $$file}; \
								} \
							} \
						} \
						for $$size (sort(keys(%size))) \
						{ \
							printf("%4d: %s\n", \
									hex($$size{$$size}{"size"}), \
									$$size{$$size}{"id"}); \
						} \
						printf("size: %u, free: %u\n", $$top - hex('$(4)'), ($(3) * 1024) - ($$top - hex('$(4)'))); \
						close($$fd);'

CC					:= $(SDKROOT)/xtensa-lx106-elf/bin/xtensa-lx106-elf-gcc
OBJCOPY				:= $(SDKROOT)/xtensa-lx106-elf/bin/xtensa-lx106-elf-objcopy

LDSCRIPT_TEMPLATE	:= loadscript-template
LDSCRIPT			:= loadscript
ELF_PLAIN			:= espiobridge-plain.o
ELF_OTA				:= espiobridge-rboot.o
OFFSET_IRAM_PLAIN	:= 0x00000
OFFSET_IROM_PLAIN	:= 0x10000
OFFSET_BOOT_OTA		:= 0x00000
OFFSET_CONFIG_OTA	:= 0x01000
OFFSET_IMG_OTA_0	:= 0x002000
OFFSET_IMG_OTA_1	:= 0x102000
FIRMWARE_PLAIN_IRAM	:= espiobridge-plain-iram-$(OFFSET_IRAM_PLAIN).bin
FIRMWARE_PLAIN_IROM	:= espiobridge-plain-irom-$(OFFSET_IROM_PLAIN).bin
FIRMWARE_RBOOT_BOOT	:= espiobridge-rboot-boot.bin
FIRMWARE_OTA_IMG	:= espiobridge-rboot-image.bin
CONFIG_RBOOT_SRC	:= rboot-config.c
CONFIG_RBOOT_ELF	:= rboot-config.o
CONFIG_RBOOT_BIN	:= rboot-config.bin
LINKMAP				:= linkmap
SDKLIBDIR			:= $(SDKROOT)/sdk/lib
LIBMAIN_PLAIN		:= main
LIBMAIN_PLAIN_FILE	:= $(SDKROOT)/sdk/lib/lib$(LIBMAIN_PLAIN).a
LIBMAIN_RBB			:= main-rbb
LIBMAIN_RBB_FILE	:= lib$(LIBMAIN_RBB).a
ESPTOOL2_BIN		:= $(ESPTOOL2)/esptool2
RBOOT_BIN			:= $(RBOOT)/firmware/rboot.bin

V ?= $(VERBOSE)
ifeq ($(V),1)
	Q :=
	VECHO := @true
	MAKEMINS :=
else
	Q := @
	VECHO := @echo
	MAKEMINS := -s
endif

ifeq ($(IMAGE),plain)
	IMAGE_OTA := 0
	FLASH_SIZE_ESPTOOL := 4m
	FLASH_SIZE_KBYTES := 512
	RBOOT_SPI_SIZE := 512K
	USER_CONFIG_SECTOR := 7a
	LD_ADDRESS := 0x40210000
	LD_LENGTH := 0x79000
	ELF := $(ELF_PLAIN)
	ALL_TARGETS := $(FIRMWARE_PLAIN_IRAM) $(FIRMWARE_PLAIN_IROM)
	FLASH_TARGET := flash-plain
	OTA_TARGET :=
endif

ifeq ($(IMAGE),ota)
	IMAGE_OTA := 1
	FLASH_SIZE_ESPTOOL := 16m
	FLASH_SIZE_KBYTES := 2048
	RBOOT_SPI_SIZE := 2M
	USER_CONFIG_SECTOR := fa
	LD_ADDRESS := 0x40202010
	LD_LENGTH := 0xf7ff0
	ELF := $(ELF_OTA)
	ALL_TARGETS := $(FIRMWARE_RBOOT_BOOT) $(CONFIG_RBOOT_BIN) $(FIRMWARE_OTA_IMG) otapush
	FLASH_TARGET := flash-ota
	OTA_TARGET := push-ota
endif

USER_CONFIG_SECTOR_HEX := 0x$(USER_CONFIG_SECTOR)

WARNINGS1		:= -Wall -Wextra -Werror -Wformat=2 -Wuninitialized -Wno-pointer-sign \
					-Wno-unused-parameter -Wsuggest-attribute=const -Wsuggest-attribute=pure \
					-Wno-div-by-zero -Wfloat-equal -Wno-declaration-after-statement -Wundef \
					-Wshadow -Wpointer-arith -Wbad-function-cast \
					-Wcast-qual -Wwrite-strings -Wsequence-point -Wclobbered \
					-Wlogical-op -Wmissing-field-initializers -Wpacked -Wredundant-decls \
					-Wnested-externs -Wlong-long -Wvla -Wdisabled-optimization -Wunreachable-code \
					-Wtrigraphs -Wreturn-type -Wmissing-braces -Wparentheses -Wimplicit \
					-Winit-self -Wformat-nonliteral -Wcomment
WARNINGS2		:= -Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition -Wcast-align -Wno-format-security -Wno-format-nonliteral
CFLAGS			:=  -Os -nostdlib -mlongcalls -mtext-section-literals -ffunction-sections -fdata-sections -D__ets__ -Wframe-larger-than=384 \
					-DICACHE_FLASH -DIMAGE_TYPE=$(IMAGE) -DIMAGE_OTA=$(IMAGE_OTA) -DUSER_CONFIG_SECTOR=$(USER_CONFIG_SECTOR_HEX)
HOSTCFLAGS		:= -O3 -lssl -lcrypto
CINC			:= -I$(SDKROOT)/lx106-hal/include -I$(SDKROOT)/xtensa-lx106-elf/xtensa-lx106-elf/include \
					-I$(SDKROOT)/xtensa-lx106-elf/xtensa-lx106-elf/sysroot/usr/include \
					-isystem$(SDKROOT)/sdk/include -I$(RBOOT)/appcode -I$(RBOOT) -I.
LDFLAGS			:= -L . -L$(SDKLIBDIR) -Wl,--gc-sections -Wl,-Map=$(LINKMAP) -nostdlib -Wl,--no-check-sections -u call_user_start -Wl,-static
SDKLIBS			:= -lc -lgcc -lhal -lpp -lphy -lnet80211 -llwip -lwpa -lpwm -lcrypto

OBJS			:= application.o config.o display.o gpios.o http.o i2c.o i2c_sensor.o queue.o stats.o uart.o user_main.o util.o
OTA_OBJ			:= rboot-bigflash.o rboot-api.o ota.o
HEADERS			:= application.h application-parameters.h config.h display.h esp-uart-register.h gpios.h http.h i2c.h \
					i2c_sensor.h ota.h queue.h stats.h uart.h user_config.h user_main.h util.h

.PRECIOUS:		*.c *.h
.PHONY:			all flash flash-plain flash-ota clean free linkdebug always ota

all:			$(ALL_TARGETS) free
				$(VECHO) "DONE $(IMAGE) TARGETS $(ALL_TARGETS) CONFIG SECTOR $(USER_CONFIG_SECTOR_HEX)"

clean:
				$(VECHO) "CLEAN"
				$(Q) $(MAKE) $(MAKEMINS) -C $(ESPTOOL2) clean
				$(Q) $(MAKE) $(MAKEMINS) -C $(RBOOT) clean
				$(Q) rm -f $(OBJS) $(OTA_OBJ) \
						$(ELF_PLAIN) $(ELF_OTA) \
						$(FIRMWARE_PLAIN_IRAM) $(FIRMWARE_PLAIN_IROM) \
						$(FIRMWARE_RBOOT_BOOT) $(FIRMWARE_OTA_IMG) \
						$(LDSCRIPT) \
						$(CONFIG_RBOOT_ELF) $(CONFIG_RBOOT_BIN) \
						$(LIBMAIN_RBB_FILE) $(ZIP) $(LINKMAP) otapush

free:			$(ELF)
				$(VECHO) "MEMORY USAGE"
				$(call section_free,$(ELF),iram,.text,,32)
				$(call section_free,$(ELF),dram,.bss,.data,80)
				$(call section_free,$(ELF),irom,.rodata,.irom0.text,424)

linkdebug:		$(LINKMAP)
				$(Q) echo "IROM:"
				$(call link_debug,$<,irom0.text,424,40210000)
				$(Q) echo "IRAM:"
				$(call link_debug,$<,text,32,40100000)



application.o:		$(HEADERS)
config.o:			$(HEADERS)
display.o:			$(HEADERS)
gpios.o:			$(HEADERS)
http.o:				$(HEADERS)
i2c.o:				$(HEADERS)
i2c_sensor.o:		$(HEADERS)
ota.o:				$(HEADERS)
otapush.o:			$(HEADERS)
queue.c:			$(HEADERS)
rboot-config.o:		$(HEADERS)
stats.o:			$(HEADERS) always
test.o:				$(HEADERS)
uart.o:				$(HEADERS)
user_main.o:		$(HEADERS)
util.o:				$(HEADERS)
rboot-api.o:		$(HEADERS)
rboot-bigflash.o:	$(HEADERS)
$(LINKMAP):			$(ELF_OTA)

$(ESPTOOL2_BIN):
						$(VECHO) "MAKE ESPTOOL2"
						$(Q) $(MAKE) $(MAKEMINS) -C $(ESPTOOL2)

$(RBOOT_BIN):			$(ESPTOOL2_BIN)
						$(VECHO) "MAKE RBOOT"
						$(Q) $(MAKE) $(MAKEMINS) -C $(RBOOT) RBOOT_BIG_FLASH=1 SPI_SIZE=$(RBOOT_SPI_SIZE) SPI_MODE=$(SPI_FLASH_MODE)

$(LDSCRIPT):			$(LDSCRIPT_TEMPLATE)
						$(VECHO) "LINKER SCRIPT $(LD_ADDRESS) $(LD_LENGTH) $@"
						$(Q) sed -e 's/@IROM0_SEG_ADDRESS@/$(LD_ADDRESS)/' -e 's/@IROM_SEG_LENGTH@/$(LD_LENGTH)/' < $< > $@

$(ELF_PLAIN):			$(OBJS) $(LDSCRIPT)
						$(VECHO) "LD PLAIN"
						$(Q) $(CC) -T./$(LDSCRIPT) $(LDFLAGS) -Wl,--start-group -l$(LIBMAIN_PLAIN) $(SDKLIBS) $(OBJS) -Wl,--end-group -o $@

$(LIBMAIN_RBB_FILE):	$(LIBMAIN_PLAIN_FILE)
						$(VECHO) "TWEAK LIBMAIN $@"
						$(Q) $(OBJCOPY) -W Cache_Read_Enable_New $< $@

$(ELF_OTA):				$(OBJS) $(OTA_OBJ) $(LIBMAIN_RBB_FILE) $(LDSCRIPT)
						$(VECHO) "LD OTA"
						$(Q) $(CC) -T./$(LDSCRIPT) $(LDFLAGS) -Wl,--start-group -l$(LIBMAIN_RBB) $(SDKLIBS) $(OTA_OBJ) $(OBJS) -Wl,--end-group -o $@

$(FIRMWARE_PLAIN_IRAM):	$(ELF_PLAIN) $(ESPTOOL2_BIN)
						$(VECHO) "PLAIN FIRMWARE IRAM $@"
						$(Q) $(ESPTOOL2_BIN) -quiet -bin -$(FLASH_SIZE_KBYTES) -$(SPI_FLASH_MODE) -boot0 $< $@ .text .data .rodata

$(FIRMWARE_PLAIN_IROM):	$(ELF_PLAIN) $(ESPTOOL2_BIN)
						$(VECHO) "PLAIN FIRMWARE IROM $@"
						$(Q) $(ESPTOOL2_BIN) -quiet -lib -$(FLASH_SIZE_KBYTES) -$(SPI_FLASH_MODE) $< $@

$(FIRMWARE_RBOOT_BOOT):	$(RBOOT_BIN)
						cp $< $@

$(FIRMWARE_OTA_IMG):	$(ELF_OTA) $(ESPTOOL2_BIN)
						$(VECHO) "RBOOT FIRMWARE $@"
						$(Q) $(ESPTOOL2_BIN) -quiet -bin -$(FLASH_SIZE_KBYTES) -$(SPI_FLASH_MODE) -boot2 $< $@ .text .data .rodata

$(CONFIG_RBOOT_BIN):	$(CONFIG_RBOOT_ELF)
						$(VECHO) "RBOOT CONFIG $@"
						$(Q) $(OBJCOPY) --output-target binary $< $@

flash:					$(FLASH_TARGET)

flash-plain:			$(FIRMWARE_PLAIN_IRAM) $(FIRMWARE_PLAIN_IROM) free
						$(VECHO) "FLASH PLAIN"
						$(Q) $(ESPTOOL) write_flash --flash_size $(FLASH_SIZE_ESPTOOL) --flash_mode $(SPI_FLASH_MODE) \
							$(OFFSET_IRAM_PLAIN) $(FIRMWARE_PLAIN_IRAM) \
							$(OFFSET_IROM_PLAIN) $(FIRMWARE_PLAIN_IROM)

flash-ota:				$(FIRMWARE_RBOOT_BOOT) $(CONFIG_RBOOT_BIN) $(FIRMWARE_OTA_IMG) free
						$(VECHO) "FLASH RBOOT"
						$(Q) $(ESPTOOL) write_flash --flash_size $(FLASH_SIZE_ESPTOOL) --flash_mode $(SPI_FLASH_MODE) \
							$(OFFSET_BOOT_OTA) $(FIRMWARE_RBOOT_BOOT) \
							$(OFFSET_CONFIG_OTA) $(CONFIG_RBOOT_BIN) \
							$(OFFSET_IMG_OTA_0) $(FIRMWARE_OTA_IMG)
#							$(OFFSET_IMG_OTA_1) $(FIRMWARE_OTA_IMG)

ota:					$(OTA_TARGET)

push-ota:				$(FIRMWARE_OTA_IMG) free otapush
						./otapush $(OTA_HOST) $(FIRMWARE_OTA_IMG)

%.o:					%.c
						$(VECHO) "CC $<"
						$(Q) $(CC) $(WARNINGS1) $(WARNINGS2) $(CFLAGS) $(CINC) -c $< -o $@

%.o:					%.ci
						$(VECHO) "CCI $<"
						$(Q) $(CC) -x c $(WARNINGS1) $(CFLAGS) -I$(RBOOT) $(CINC) -c $< -o $@

otapush:				otapush.c
						$(VECHO) "HOST CC $<"
						$(Q) $(HOSTCC) $(HOSTCFLAGS) $(WARNINGS1) $(WARNINGS2) $< -o $@

NASM = nasm
BUILD = build

all: $(BUILD)/DAPING.COM $(BUILD)/DASTUB.COM $(BUILD)/GOTEKHDD.SYS \
	$(BUILD)/DRVTEST.COM

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/DAPING.COM: src/daping.asm src/da.asm src/structs.inc | $(BUILD)
	$(NASM) -f bin -i src/ $< -o $@

$(BUILD)/GOTEKHDD.SYS: src/gotekhdd.asm src/da.asm src/extent.asm \
		src/init.asm src/structs.inc | $(BUILD)
	$(NASM) -f bin -i src/ $< -o $@

$(BUILD)/DASTUB.COM: test/dastub.asm src/structs.inc | $(BUILD)
	$(NASM) -f bin -i src/ $< -o $@

$(BUILD)/DRVTEST.COM: test/drvtest.asm src/structs.inc | $(BUILD)
	$(NASM) -f bin -i src/ $< -o $@

image: | $(BUILD)
	python3 tools/mkimage.py $(BUILD)/gotekhdd.img --size 32M

card: image
	python3 tools/mkimage.py $(BUILD)/card.img --card \
		--image $(BUILD)/gotekhdd.img --fragments 4

clean:
	rm -rf $(BUILD)

.PHONY: all image card clean

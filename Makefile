OUT = out
SOURCE = simulatore_python.md

$(OUT)/relazione.pdf $(OUT)/relazione.tex: $(SOURCE) | $(OUT) 
	pandoc $(SOURCE) -o $@

$(OUT):
	mkdir -p $(OUT)

clean:
	rm -rf $(OUT)

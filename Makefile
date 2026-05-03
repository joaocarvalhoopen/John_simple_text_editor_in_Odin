all:
	odin build . -out:john.exe -o:speed
    
clean:
	rm -f ./john.exe

run:
	./john.exe
	
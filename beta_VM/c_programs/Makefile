TARGET = log_report

# compiles the source file (log_report.c)
# into an executable named "log_report"
build: $(TARGET).c
	gcc -Wall -Wextra -o $(TARGET) $(TARGET).c

run: build
	./beta_log_report.sh

# removes the compiled executable file to keep the directory clean
clean:
	rm -f $(TARGET)

.PHONY: build run clean
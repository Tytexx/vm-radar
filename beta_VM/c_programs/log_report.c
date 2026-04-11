/*
 * Processes multiple log files in parallel using fork()
 *
 * For each file a child process is created using fork(), 
 * the child reads the file and counts total lines, 
 * WARNING lines, CRITICAL lines, then it extracts 
 * the last timestamp and sends results to the parent via a pipe
 *
 * The parent collects all child summaries, waits for all
 * children to finish, prints a formatted report
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#define MAX_LINE    1024
#define MAX_SUMMARY 512
#define MAX_FILES   64

// Function executed by each child process
void child_process(const char *filepath, int write_fd) {

// track statistics for the current log file
    int total_lines = 0;
    int warning_count = 0;
    int critical_count = 0;

    char last_line[MAX_LINE] = "";  // stores last line read
    char line[MAX_LINE];

    // Open log file
    FILE *fp = fopen(filepath, "r");

    if (fp == NULL) {
        // If file can't be opened, send error summary to parent
        fprintf(stderr, "ERROR: Cannot open file: %s\n", filepath);

        char error_summary[MAX_SUMMARY];
        snprintf(error_summary, sizeof(error_summary),
                 "%s|0|0|0|ERROR\n", filepath);
        write(write_fd, error_summary, strlen(error_summary));
        close(write_fd);

        exit(1);
    }

    // Read file line by line
    while (fgets(line, sizeof(line), fp) != NULL) {

        total_lines++;

        // Count WARNING occurrences
        if (strstr(line, "WARNING") != NULL) {
            warning_count++;
        }

        // Count CRITICAL occurrences
        if (strstr(line, "CRITICAL") != NULL) {
            critical_count++;
        }

        // Keep updating last_line → ends up as final line in file
        strncpy(last_line, line, sizeof(last_line) - 1);
        last_line[sizeof(last_line) - 1] = '\0';
    }

    fclose(fp);

    // Extract timestamp (first word of last line)
    char last_timestamp[64] = "N/A";

    if (strlen(last_line) > 0) {
        // Remove newline
        char *newline = strchr(last_line, '\n');
        if (newline != NULL) {
            *newline = '\0';
        }
        // Extract substring before first space
        char *space = strchr(last_line, ' ');
        if (space != NULL) {
            int len = space - last_line;
            if (len > 0 && len < (int)sizeof(last_timestamp) - 1) {
                strncpy(last_timestamp, last_line, len);
                last_timestamp[len] = '\0';
            }
        } else {
            // If no space, use entire line
            strncpy(last_timestamp, last_line, sizeof(last_timestamp) - 1);
        }
    }

    // Extract filename from path
    const char *filename = strrchr(filepath, '/');
    if (filename != NULL) {
        filename++;
    } else {
        filename = filepath;
    }
    // format summary string: file|lines|warnings|criticals|timestamp
    char summary[MAX_SUMMARY];
    snprintf(summary, sizeof(summary),
             "%s|%d|%d|%d|%s\n",
             filename, total_lines, warning_count, critical_count, last_timestamp);

    // send summary from child to parent through pipe
    write(write_fd, summary, strlen(summary));
    close(write_fd);

    exit(0);    // child exits
}

int main(int argc, char *argv[]) {

    // Require at least one file
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <logfile1> [logfile2 ...]\n", argv[0]);
        fprintf(stderr, "Example: %s ~/beta_VM/logs/alerts.log\n", argv[0]);
        return 1;
    }

    int num_files = argc - 1;

    // Prevent too many child processes
    if (num_files > MAX_FILES) {
        fprintf(stderr, "ERROR: Too many files. Max is %d\n", MAX_FILES);
        return 1;
    }

    int pipefd[2];

    // Create pipe
    if (pipe(pipefd) == -1) {
        perror("pipe");
        return 1;
    }

    pid_t pids[MAX_FILES];

    // Fork one child per file
    for (int i = 0; i < num_files; i++) {
        pid_t pid = fork();

        if (pid == -1) {
            perror("fork");
            return 1;
        }

        if (pid == 0) {
            close(pipefd[0]);
            // Process assigned file
            child_process(argv[i + 1], pipefd[1]);

            exit(0);
        }
        // Parent stores child PID
        pids[i] = pid;
    }

    close(pipefd[1]);

    // Buffer to store all summaries from children
    char all_data[MAX_SUMMARY * MAX_FILES];
    memset(all_data, 0, sizeof(all_data));

    int total_bytes = 0;
    int bytes_read;
    char read_buf[256];

    // Read all data sent through pipe
    while ((bytes_read = read(pipefd[0], read_buf, sizeof(read_buf) - 1)) > 0) {
        read_buf[bytes_read] = '\0';

        // Append safely to all_data
        if (total_bytes + bytes_read < (int)sizeof(all_data) - 1) {
            strcat(all_data, read_buf);
            total_bytes += bytes_read;
        }
    }

    close(pipefd[0]);

    // Track exit status of child
    int exited_ok = 0;
    int exited_err = 0;

    // Wait for all children to finish
    for (int i = 0; i < num_files; i++) {
        int status;

        waitpid(pids[i], &status, 0);

        if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
            exited_ok++;
        } else {
            exited_err++;
        }
    }

    // totals across all files
    int grand_total_lines = 0;
    int grand_total_warnings = 0;
    int grand_total_criticals = 0;

    // Print log summary report
    printf("\nLOG SUMMARY REPORT\n");
    printf("============================================================\n");
    printf("%-20s %8s %10s %11s  %s\n",
           "File", "Lines", "Warnings", "Criticals", "Last Entry");
    printf("------------------------------------------------------------\n");

    // Copying data and working on the copied data, so original data is safe. 
    // because strtok modifies string
    char data_copy[sizeof(all_data)];
    strncpy(data_copy, all_data, sizeof(data_copy) - 1);
    data_copy[sizeof(data_copy) - 1] = '\0';

    // Process each summary line
    char *line_token = strtok(data_copy, "\n");

    while (line_token != NULL) {

        if (strlen(line_token) == 0) {
            line_token = strtok(NULL, "\n");
            continue;
        }
        // Split fields using '|'
        char line_copy[MAX_SUMMARY];
        strncpy(line_copy, line_token, sizeof(line_copy) - 1);
        line_copy[sizeof(line_copy) - 1] = '\0';

        char *fname    = strtok(line_copy, "|");
        char *s_lines  = strtok(NULL, "|");
        char *s_warns  = strtok(NULL, "|");
        char *s_crits  = strtok(NULL, "|");
        char *s_ts     = strtok(NULL, "|");

        if (!fname || !s_lines || !s_warns || !s_crits || !s_ts) {
            line_token = strtok(NULL, "\n");
            continue;
        }
        // Convert string values to integers
        int lines = atoi(s_lines);
        int warns = atoi(s_warns);
        int crits = atoi(s_crits);

        // print each row
        printf("%-20s %8d %10d %11d  %s\n",
               fname, lines, warns, crits, s_ts);

        // Update the totals
        grand_total_lines    += lines;
        grand_total_warnings += warns;
        grand_total_criticals += crits;

        line_token = strtok(NULL, "\n");
    }

    // Print the totals
    printf("------------------------------------------------------------\n");
    printf("%-20s %8d %10d %11d\n",
           "TOTAL",
           grand_total_lines,
           grand_total_warnings,
           grand_total_criticals);
    printf("============================================================\n");
    // Print child summary
    printf("CHILDREN: forked=%d exited_ok=%d exited_err=%d\n\n",
           num_files, exited_ok, exited_err);

    return 0;
}
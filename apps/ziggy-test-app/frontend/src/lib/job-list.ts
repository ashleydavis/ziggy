//
// Keeps the running list of jobs from the job-progress events tasks send, the way the real frontend does: a task
// that reports a job id counts towards that job, and the job is dropped when the last task carrying its id completes.
//

//
// A job's identity, as a task reports it in a job-progress event.
//
export interface IJobTag {
    // The job's id. Tasks sharing an id are one job.
    id: string;

    // The job's name.
    name: string;

    // The source whose cancellation cancels the job, when it has one.
    cancelSource?: string;
}

//
// A job-progress event, with the fields of the core's IJobProgressEvent.
//
export interface IJobProgressEvent {
    // Always "job-progress".
    type: "job-progress";

    // The job the event is about.
    job: IJobTag;

    // When the job started, in milliseconds since the Unix epoch.
    startedAt: number;

    // What the job is doing now.
    progressMessage?: string;
}

//
// A job as the frontend lists it.
//
export interface IJob {
    // The job's id.
    id: string;

    // The job's name.
    name: string;

    // The source whose cancellation cancels the job, when it has one.
    cancelSource?: string;

    // When the job started.
    startedAt: number;

    // The latest thing the job reported it was doing.
    progressMessage?: string;
}

//
// The list of jobs, and which job each running task has reported.
//
export interface IJobList {
    // The jobs, in the order they first reported.
    jobs: IJob[];

    // The job id each task has reported, by task id.
    taskJobIds: { [taskId: string]: string };
}

//
// A list with no jobs.
//
export function emptyJobList(): IJobList {
    return {
        jobs: [],
        taskJobIds: {},
    };
}

//
// Applies a job-progress event sent by a task. A first event from a job adds it, and a later one updates what it
// reports it is doing.
//
export function applyJobProgress(list: IJobList, taskId: string, event: IJobProgressEvent): IJobList {
    const taskJobIds = { ...list.taskJobIds, [taskId]: event.job.id };
    const existing = list.jobs.find(job => job.id === event.job.id);
    if (!existing) {
        return {
            jobs: [
                ...list.jobs,
                {
                    id: event.job.id,
                    name: event.job.name,
                    cancelSource: event.job.cancelSource,
                    startedAt: event.startedAt,
                    progressMessage: event.progressMessage,
                },
            ],
            taskJobIds,
        };
    }
    return {
        jobs: list.jobs.map(job => job.id === event.job.id ? { ...job, progressMessage: event.progressMessage } : job),
        taskJobIds,
    };
}

//
// Applies the completion of a task. The job the task reported is dropped when no other task still carries its id.
//
export function applyTaskCompleted(list: IJobList, taskId: string): IJobList {
    const jobId = list.taskJobIds[taskId];
    if (jobId === undefined) {
        return list;
    }
    const taskJobIds = { ...list.taskJobIds };
    delete taskJobIds[taskId];
    const stillCarried = Object.values(taskJobIds).includes(jobId);
    return {
        jobs: stillCarried ? list.jobs : list.jobs.filter(job => job.id !== jobId),
        taskJobIds,
    };
}

import { DownloadRecord } from '../../model/DownloadRecord';
import { DownloadRunRequest, cloneDownloadRunRequest } from '../../model/DownloadRunRequest';
import { cloneDownloadRequestContext } from '../../model/DownloadRequestContext';

// Only committed database snapshots are published here. IDs are never reused.
const committedRequests: Map<string, DownloadRunRequest> = new Map<string, DownloadRunRequest>();
const deletedRequests: Set<string> = new Set<string>();

export function publishCommittedRequest(id: string, request: DownloadRunRequest): void {
  if (deletedRequests.has(id)) { return; }
  if (!Number.isSafeInteger(request.revision) || request.revision < 0) {
    throw new Error('Invalid request revision');
  }
  const previous: DownloadRunRequest | undefined = committedRequests.get(id);
  if (previous === undefined || request.revision > previous.revision) {
    committedRequests.set(id, cloneDownloadRunRequest(request));
  }
}

export function forgetRequest(id: string): void {
  committedRequests.delete(id);
  deletedRequests.add(id);
}

export function resolveRunRequest(record: DownloadRecord): DownloadRunRequest {
  if (deletedRequests.has(record.id)) { throw new Error('Download was deleted'); }
  const saved: DownloadRunRequest | undefined = committedRequests.get(record.id);
  // A mutable caller record cannot promote an uncommitted revision over Store publication.
  // Every production load/write publishes before exposing its record to a new run.
  if (saved !== undefined) {
    return cloneDownloadRunRequest(saved);
  }
  const request: DownloadRunRequest = new DownloadRunRequest();
  request.url = record.primaryUrl ?? '';
  request.context = cloneDownloadRequestContext(record.requestContext);
  request.revision = record.requestRevision;
  if (!Number.isSafeInteger(request.revision) || request.revision < 0) {
    throw new Error('Invalid request revision');
  }
  return request;
}

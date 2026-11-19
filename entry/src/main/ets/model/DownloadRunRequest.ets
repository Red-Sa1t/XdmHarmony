import { DownloadRequestContext, cloneDownloadRequestContext } from './DownloadRequestContext';

/** Transport input for one run; never shares mutable header arrays with a record. */
export class DownloadRunRequest {
  url: string = '';
  context: DownloadRequestContext = new DownloadRequestContext();
  revision: number = 0;
}

export function cloneDownloadRunRequest(request: DownloadRunRequest): DownloadRunRequest {
  const copy: DownloadRunRequest = new DownloadRunRequest();
  copy.url = request.url;
  copy.context = cloneDownloadRequestContext(request.context);
  copy.revision = request.revision;
  return copy;
}

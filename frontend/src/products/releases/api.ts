import type { APRelease, RolloutEvent, ProductConfig, ReleaseDiff, PodHealthResponse, ResourceInfo } from '../../api';
import {
  fetchAPReleases, fetchReleaseDetails, fetchReleaseEvents, fetchProductConfigs,
  fetchProducts, fetchServices, fetchEnvs, fetchSecondaryEnvs, createRelease,
  approveRelease, rollbackRelease, revertRelease, discardRelease, updateTracker,
  pauseRelease, resumeRelease, abortRelease, immediateRevert, deleteRelease,
  restartRelease, fastForwardRelease, immediateRevertRelease,
  fetchReleaseDiff, fetchPodHealth, fetchResources,
} from '../../api';

// Re-export everything from the existing api.ts for releases
export {
  fetchAPReleases, fetchReleaseDetails, fetchReleaseEvents, fetchProductConfigs,
  fetchProducts, fetchServices, fetchEnvs, fetchSecondaryEnvs, createRelease,
  approveRelease, rollbackRelease, revertRelease, discardRelease, updateTracker,
  pauseRelease, resumeRelease, abortRelease, immediateRevert, deleteRelease,
  restartRelease, fastForwardRelease, immediateRevertRelease,
  fetchReleaseDiff, fetchPodHealth, fetchResources,
};

export type { APRelease, RolloutEvent, ProductConfig, ReleaseDiff, PodHealthResponse, ResourceInfo };

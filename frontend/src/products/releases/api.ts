import type { APRelease, RolloutEvent, ProductConfig } from '../../api';
import { fetchAPReleases, fetchReleaseDetails, fetchReleaseEvents, fetchProductConfigs, fetchProducts, fetchServices, fetchEnvs, fetchSecondaryEnvs, createRelease, approveRelease, rollbackRelease, revertRelease, discardRelease, updateTracker, pauseRelease, resumeRelease, abortRelease, immediateRevert } from '../../api';

// Re-export everything from the existing api.ts for releases
export {
  fetchAPReleases,
  fetchReleaseDetails,
  fetchReleaseEvents,
  fetchProductConfigs,
  fetchProducts,
  fetchServices,
  fetchEnvs,
  fetchSecondaryEnvs,
  createRelease,
  approveRelease,
  rollbackRelease,
  revertRelease,
  discardRelease,
  updateTracker,
  pauseRelease,
  resumeRelease,
  abortRelease,
  immediateRevert,
};

export type { APRelease, RolloutEvent, ProductConfig };

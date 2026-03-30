import type { APRelease, RolloutEvent, ProductConfig } from '../../api';
import { fetchAPReleases, fetchReleaseDetails, fetchReleaseEvents, fetchProductConfigs, fetchProducts, fetchServices, fetchEnvs, fetchSecondaryEnvs, createRelease, approveRelease, rollbackRelease, revertRelease, discardRelease, updateTracker, pauseRelease, resumeRelease, abortRelease, immediateRevert, deleteRelease } from '../../api';

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
  deleteRelease,
};

export type { APRelease, RolloutEvent, ProductConfig };

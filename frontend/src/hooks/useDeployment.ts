import { useQuery } from "@tanstack/react-query";
import { fetchDeployment } from "../config/deployment";

export function useDeployment() {
  return useQuery({
    queryKey: ["deployment"],
    queryFn: fetchDeployment,
    staleTime: Infinity,
    retry: false,
  });
}
